import { BadRequestException, Injectable } from '@nestjs/common';
import { unzipSync, type UnzipFileInfo } from 'fflate';
import { posix } from 'node:path';
import { PluginManifestDto } from 'src/dtos/plugin-manifest.dto.js';
import {
  PluginMethodResponseDto,
  PluginMethodSearchDto,
  PluginResponseDto,
  PluginSearchDto,
  PluginTemplateResponseDto,
  mapMethod,
  mapPlugin,
  mapTemplate,
} from 'src/dtos/plugin.dto.js';
import { BaseService } from 'src/services/base.service.js';
import { isMethodCompatible } from 'src/utils/workflow.js';

const CORE_PLUGIN_NAME = 'immich-plugin-core';
const MAX_PACKAGE_ENTRY_SIZE = 100 * 1024 * 1024;
const MANIFEST_FILENAME = 'manifest.json';

@Injectable()
export class PluginService extends BaseService {
  async search(dto: PluginSearchDto): Promise<PluginResponseDto[]> {
    const plugins = await this.pluginRepository.search(dto);
    return plugins.map((plugin) => mapPlugin(plugin));
  }

  async get(id: string): Promise<PluginResponseDto> {
    const plugin = await this.pluginRepository.get(id);
    if (!plugin) {
      throw new BadRequestException('Plugin not found');
    }
    return mapPlugin(plugin);
  }

  async searchMethods(dto: PluginMethodSearchDto): Promise<PluginMethodResponseDto[]> {
    const methods = await this.pluginRepository.searchMethods(dto);
    return methods
      .filter((method) => !dto.trigger || isMethodCompatible(method, dto.trigger))
      .map((method) => mapMethod(method));
  }

  async searchTemplates(): Promise<PluginTemplateResponseDto[]> {
    const plugins = await this.pluginRepository.search();
    return plugins.flatMap((plugin) => plugin.templates.map((template) => mapTemplate(plugin, template)));
  }

  async install(file?: Express.Multer.File): Promise<PluginResponseDto> {
    if (!file?.buffer?.length) {
      throw new BadRequestException('A plugin package file is required');
    }

    const { manifest, manifestBytes, wasmBytes } = this.readPackage(file.buffer);
    if (manifest.name === CORE_PLUGIN_NAME) {
      throw new BadRequestException(`The plugin name "${CORE_PLUGIN_NAME}" is reserved`);
    }

    const { id } = await this.pluginRepository.upsert(
      {
        enabled: true,
        name: manifest.name,
        title: manifest.title,
        description: manifest.description,
        author: manifest.author,
        version: manifest.version,
        templates: manifest.templates,
        wasmBytes,
        sha256hash: this.cryptoRepository.hashSha256(Buffer.concat([manifestBytes, wasmBytes])),
      },
      manifest.methods,
    );

    this.logger.log(`Installed plugin ${manifest.name}@${manifest.version} from upload`);
    await this.eventRepository.emit('PluginUpdate');

    return this.get(id);
  }

  async uninstall(id: string): Promise<void> {
    const plugin = await this.pluginRepository.get(id);
    if (!plugin) {
      throw new BadRequestException('Plugin not found');
    }

    if (plugin.name === CORE_PLUGIN_NAME) {
      throw new BadRequestException('The core plugin cannot be uninstalled');
    }

    await this.pluginRepository.delete(id);
    this.logger.log(`Uninstalled plugin ${plugin.name}@${plugin.version}`);
    await this.eventRepository.emit('PluginUpdate');
  }

  private readPackage(buffer: Buffer) {
    const archive = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    const extract = (accept: (entry: UnzipFileInfo) => boolean) => {
      try {
        return unzipSync(archive, {
          filter: (entry) => {
            if (!accept(entry)) {
              return false;
            }
            if (entry.originalSize > MAX_PACKAGE_ENTRY_SIZE) {
              throw new Error(`${entry.name} is too large`);
            }
            return true;
          },
        });
      } catch (error: Error | any) {
        throw new BadRequestException(`Invalid plugin package: ${error?.message ?? error}`);
      }
    };

    const manifestEntries = extract((entry) => posix.basename(entry.name) === MANIFEST_FILENAME);
    const [manifestPath] = Object.keys(manifestEntries).toSorted((a, b) => a.length - b.length);
    if (!manifestPath) {
      throw new BadRequestException(`Invalid plugin package: ${MANIFEST_FILENAME} not found`);
    }

    const manifestBytes = Buffer.from(manifestEntries[manifestPath]);
    const manifest = this.parseManifest(manifestBytes);

    const wasmPath = posix.join(posix.dirname(manifestPath), manifest.wasmPath);
    const wasmEntries = extract((entry) => posix.normalize(entry.name) === wasmPath);
    const wasm = Object.values(wasmEntries)[0];
    if (!wasm) {
      throw new BadRequestException(`Invalid plugin package: ${manifest.wasmPath} not found`);
    }

    return { manifest, manifestBytes, wasmBytes: Buffer.from(wasm) };
  }

  private parseManifest(bytes: Buffer) {
    let json: unknown;
    try {
      json = JSON.parse(bytes.toString('utf8'));
    } catch {
      throw new BadRequestException(`Invalid plugin package: ${MANIFEST_FILENAME} is not valid JSON`);
    }

    const result = PluginManifestDto.schema.safeParse(json);
    if (!result.success) {
      const issues = result.error.issues.map((issue) => `[${issue.path.join('.')}] ${issue.message}`).join('; ');
      throw new BadRequestException(`Invalid plugin manifest: ${issues}`);
    }

    return result.data;
  }
}
