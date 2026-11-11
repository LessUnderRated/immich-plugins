import { BadRequestException } from '@nestjs/common';
import { strToU8, zipSync } from 'fflate';
import { PluginService } from 'src/services/plugin.service.js';
import { ServiceMocks, newTestService } from 'test/utils.js';

const manifest = {
  name: 'my-plugin',
  version: '1.0.0',
  title: 'My plugin',
  description: 'A test plugin',
  author: 'Tester',
  wasmPath: 'dist/plugin.wasm',
  methods: [
    {
      name: 'assetRatingFilter',
      title: 'Rating filter',
      description: 'Filter by rating',
      types: ['AssetV1'],
    },
  ],
};

const wasm = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);

const toUpload = (files: Record<string, Uint8Array>) =>
  ({ buffer: Buffer.from(zipSync(files)), originalname: 'plugin.zip' }) as Express.Multer.File;

const pluginRow = {
  id: 'plugin-1',
  name: manifest.name,
  title: manifest.title,
  description: manifest.description,
  author: manifest.author,
  version: manifest.version,
  createdAt: new Date('2026-01-01'),
  updatedAt: new Date('2026-01-01'),
  templates: [],
  methods: [],
};

describe(PluginService.name, () => {
  let sut: PluginService;
  let mocks: ServiceMocks;

  beforeEach(() => {
    ({ sut, mocks } = newTestService(PluginService));
  });

  describe('install', () => {
    it('should require a file', async () => {
      await expect(sut.install()).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.plugin.upsert).not.toHaveBeenCalled();
    });

    it('should reject a file that is not a zip', async () => {
      const file = { buffer: Buffer.from('not a zip') } as Express.Multer.File;
      await expect(sut.install(file)).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.plugin.upsert).not.toHaveBeenCalled();
    });

    it('should reject a package without a manifest', async () => {
      await expect(sut.install(toUpload({ 'dist/plugin.wasm': wasm }))).rejects.toThrow('manifest.json not found');
    });

    it('should reject a package without the wasm file', async () => {
      const file = toUpload({ 'manifest.json': strToU8(JSON.stringify(manifest)) });
      await expect(sut.install(file)).rejects.toThrow('dist/plugin.wasm not found');
    });

    it('should reject an invalid manifest', async () => {
      const file = toUpload({
        'manifest.json': strToU8(JSON.stringify({ ...manifest, name: 'Bad Name' })),
        'dist/plugin.wasm': wasm,
      });
      await expect(sut.install(file)).rejects.toThrow('Invalid plugin manifest');
    });

    it('should reject the reserved core plugin name', async () => {
      const file = toUpload({
        'manifest.json': strToU8(JSON.stringify({ ...manifest, name: 'immich-plugin-core' })),
        'dist/plugin.wasm': wasm,
      });
      await expect(sut.install(file)).rejects.toThrow('reserved');
    });

    it('should install a plugin and notify workers', async () => {
      mocks.plugin.upsert.mockResolvedValue({ id: 'plugin-1', name: manifest.name, methods: [] });
      mocks.plugin.get.mockResolvedValue(pluginRow);

      const file = toUpload({
        'manifest.json': strToU8(JSON.stringify(manifest)),
        'dist/plugin.wasm': wasm,
      });

      await expect(sut.install(file)).resolves.toEqual(expect.objectContaining({ id: 'plugin-1', name: 'my-plugin' }));
      expect(mocks.plugin.upsert).toHaveBeenCalledWith(
        expect.objectContaining({ name: 'my-plugin', version: '1.0.0', wasmBytes: Buffer.from(wasm) }),
        [expect.objectContaining({ name: 'assetRatingFilter' })],
      );
      expect(mocks.event.emit).toHaveBeenCalledWith('PluginUpdate');
    });

    it('should find the manifest inside a top-level folder', async () => {
      mocks.plugin.upsert.mockResolvedValue({ id: 'plugin-1', name: manifest.name, methods: [] });
      mocks.plugin.get.mockResolvedValue(pluginRow);

      const file = toUpload({
        'my-plugin/manifest.json': strToU8(JSON.stringify({ ...manifest, wasmPath: './dist/plugin.wasm' })),
        'my-plugin/dist/plugin.wasm': wasm,
      });

      await expect(sut.install(file)).resolves.toBeDefined();
      expect(mocks.plugin.upsert).toHaveBeenCalledWith(
        expect.objectContaining({ wasmBytes: Buffer.from(wasm) }),
        expect.any(Array),
      );
    });
  });

  describe('uninstall', () => {
    it('should throw when the plugin does not exist', async () => {
      mocks.plugin.get.mockResolvedValue(void 0);
      await expect(sut.uninstall('plugin-1')).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.plugin.delete).not.toHaveBeenCalled();
    });

    it('should not uninstall the core plugin', async () => {
      mocks.plugin.get.mockResolvedValue({ ...pluginRow, name: 'immich-plugin-core' });
      await expect(sut.uninstall('plugin-1')).rejects.toThrow('cannot be uninstalled');
      expect(mocks.plugin.delete).not.toHaveBeenCalled();
    });

    it('should delete the plugin and notify workers', async () => {
      mocks.plugin.get.mockResolvedValue(pluginRow);
      mocks.plugin.delete.mockResolvedValue();

      await sut.uninstall('plugin-1');

      expect(mocks.plugin.delete).toHaveBeenCalledWith('plugin-1');
      expect(mocks.event.emit).toHaveBeenCalledWith('PluginUpdate');
    });
  });
});
