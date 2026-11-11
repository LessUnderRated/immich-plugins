import {
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Query,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { ApiBody, ApiConsumes, ApiTags } from '@nestjs/swagger';
import { Endpoint, HistoryBuilder } from 'src/decorators.js';
import {
  PluginMethodResponseDto,
  PluginMethodSearchDto,
  PluginResponseDto,
  PluginSearchDto,
  PluginTemplateResponseDto,
  PluginUploadDto,
} from 'src/dtos/plugin.dto.js';
import { Permission } from 'src/enum.js';
import { Authenticated } from 'src/middleware/auth.guard.js';
import { PluginService } from 'src/services/plugin.service.js';
import { UUIDParamDto } from 'src/validation.js';

@ApiTags('Plugins')
@Controller('plugins')
export class PluginController {
  constructor(private service: PluginService) {}

  @Get()
  @Authenticated({ permission: Permission.PluginRead })
  @Endpoint({
    summary: 'List all plugins',
    description: 'Retrieve a list of plugins available to the authenticated user.',
    history: HistoryBuilder.v3(),
  })
  searchPlugins(@Query() dto: PluginSearchDto): Promise<PluginResponseDto[]> {
    return this.service.search(dto);
  }

  @Get('methods')
  @Authenticated({ permission: Permission.PluginRead })
  @Endpoint({
    summary: 'Retrieve plugin methods',
    description: 'Retrieve a list of plugin methods',
    history: HistoryBuilder.v3(),
  })
  searchPluginMethods(@Query() dto: PluginMethodSearchDto): Promise<PluginMethodResponseDto[]> {
    return this.service.searchMethods(dto);
  }

  @Get('templates')
  @Authenticated({ permission: Permission.PluginRead })
  @Endpoint({
    summary: 'Retrieve workflow templates',
    description: 'Retrieve workflow templates provided by installed plugins',
    history: HistoryBuilder.v3(),
  })
  searchPluginTemplates(): Promise<PluginTemplateResponseDto[]> {
    return this.service.searchTemplates();
  }

  @Get(':id')
  @Authenticated({ permission: Permission.PluginRead })
  @Endpoint({
    summary: 'Retrieve a plugin',
    description: 'Retrieve information about a specific plugin by its ID.',
    history: HistoryBuilder.v3(),
  })
  getPlugin(@Param() { id }: UUIDParamDto): Promise<PluginResponseDto> {
    return this.service.get(id);
  }

  @Post()
  @Authenticated({ permission: Permission.PluginCreate, admin: true })
  @ApiConsumes('multipart/form-data')
  @ApiBody({ description: 'Plugin package', type: PluginUploadDto })
  @Endpoint({
    summary: 'Install a plugin',
    description: 'Install or upgrade a plugin from a .zip package containing manifest.json and the compiled wasm file.',
    history: HistoryBuilder.v3(),
  })
  @UseInterceptors(FileInterceptor('file'))
  installPlugin(@UploadedFile() file: Express.Multer.File): Promise<PluginResponseDto> {
    return this.service.install(file);
  }

  @Delete(':id')
  @Authenticated({ permission: Permission.PluginDelete, admin: true })
  @HttpCode(HttpStatus.NO_CONTENT)
  @Endpoint({
    summary: 'Uninstall a plugin',
    description: 'Remove an installed plugin and every workflow step that uses it.',
    history: HistoryBuilder.v3(),
  })
  uninstallPlugin(@Param() { id }: UUIDParamDto): Promise<void> {
    return this.service.uninstall(id);
  }
}
