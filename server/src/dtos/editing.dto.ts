import z from 'zod';
import { createZodDto } from 'src/zod.js';

export enum AssetEditAction {
  Crop = 'crop',
  Rotate = 'rotate',
  Mirror = 'mirror',
  Mosaic = 'mosaic',
}

export const AssetEditActionSchema = z
  .enum(AssetEditAction)
  .describe('Type of edit action to perform')
  .meta({ id: 'AssetEditAction' });

export enum MirrorAxis {
  Horizontal = 'horizontal',
  Vertical = 'vertical',
}

const MirrorAxisSchema = z.enum(['horizontal', 'vertical']).describe('Axis to mirror along').meta({ id: 'MirrorAxis' });

const CropParametersSchema = z
  .object({
    x: z.int().min(0).describe('Top-Left X coordinate of crop'),
    y: z.int().min(0).describe('Top-Left Y coordinate of crop'),
    width: z.int().min(1).describe('Width of the crop'),
    height: z.int().min(1).describe('Height of the crop'),
  })
  .meta({ id: 'CropParameters' });

const RotateParametersSchema = z
  .object({
    angle: z
      .int()
      .min(0)
      .max(270)
      .refine((v) => [0, 90, 180, 270].includes(v), {
        error: 'Angle must be one of the following values: 0, 90, 180, 270',
      })
      .describe('Rotation angle in degrees'),
  })
  .meta({ id: 'RotateParameters' });

const MirrorParametersSchema = z
  .object({
    axis: MirrorAxisSchema,
  })
  .meta({ id: 'MirrorParameters' });

export enum MosaicStrokeMode {
  Paint = 'paint',
  Erase = 'erase',
}

const MosaicStrokeModeSchema = z
  .enum(MosaicStrokeMode)
  .describe('Whether the stroke adds mosaic or erases previously painted mosaic')
  .meta({ id: 'MosaicStrokeMode' });

export enum MosaicStyle {
  Pixelate = 'pixelate',
  Blur = 'blur',
  Hexagon = 'hexagon',
  StainedGlass = 'stainedGlass',
}

const MosaicStyleSchema = z.enum(MosaicStyle).describe('How a stroke censors the image').meta({ id: 'MosaicStyle' });

const MosaicPointSchema = z
  .object({
    x: z.number().describe('X coordinate in original image pixels').meta({ format: 'double' }),
    y: z.number().describe('Y coordinate in original image pixels').meta({ format: 'double' }),
  })
  .meta({ id: 'MosaicPoint' });

const MosaicStrokeSchema = z
  .object({
    mode: MosaicStrokeModeSchema,
    brushSize: z.number().positive().describe('Brush diameter in original image pixels').meta({ format: 'double' }),
    points: z.array(MosaicPointSchema).min(1).max(10_000).describe('Points along the stroke'),
    blockSize: z
      .int()
      .min(2)
      .max(1024)
      .optional()
      .describe('Mosaic block size for this stroke in original image pixels, defaults to the edit block size'),
    style: MosaicStyleSchema.optional().describe('Censor style for this stroke, defaults to pixelate'),
  })
  .meta({ id: 'MosaicStroke' });

const MosaicParametersSchema = z
  .object({
    blockSize: z.int().min(2).max(1024).describe('Default size of each mosaic block in original image pixels'),
    strokes: z.array(MosaicStrokeSchema).min(1).max(1000).describe('Brush strokes, applied in order'),
  })
  .meta({ id: 'MosaicParameters' });

// TODO: ideally we would use the discriminated union directly in the future not only for type support but also for validation and openapi generation
const __AssetEditActionItemSchema = z.discriminatedUnion('action', [
  z.object({ action: AssetEditActionSchema.extract(['Crop']), parameters: CropParametersSchema }),
  z.object({ action: AssetEditActionSchema.extract(['Rotate']), parameters: RotateParametersSchema }),
  z.object({ action: AssetEditActionSchema.extract(['Mirror']), parameters: MirrorParametersSchema }),
  z.object({ action: AssetEditActionSchema.extract(['Mosaic']), parameters: MosaicParametersSchema }),
]);

const AssetEditParametersSchema = z
  .union([CropParametersSchema, RotateParametersSchema, MirrorParametersSchema, MosaicParametersSchema], {
    error: getExpectedKeysByActionMessage,
  })
  .describe('List of edit actions to apply (crop, rotate, mirror, or mosaic)');

const actionParameterMap = {
  [AssetEditAction.Crop]: CropParametersSchema,
  [AssetEditAction.Rotate]: RotateParametersSchema,
  [AssetEditAction.Mirror]: MirrorParametersSchema,
  [AssetEditAction.Mosaic]: MosaicParametersSchema,
} as const;

function getExpectedKeysByActionMessage(): string {
  const expectedByAction = Object.entries(actionParameterMap)
    .map(([action, schema]) => `${action}: [${Object.keys(schema.shape).join(', ')}]`)
    .join('; ');

  return `Invalid parameters for action, expected keys by action: ${expectedByAction}`;
}

function isParametersValidForAction(edit: z.infer<typeof AssetEditActionItemSchema>): boolean {
  return actionParameterMap[edit.action].safeParse(edit.parameters).success;
}

const AssetEditActionItemSchema = z
  .object({
    action: AssetEditActionSchema,
    parameters: AssetEditParametersSchema,
  })
  .superRefine((edit, ctx) => {
    if (!isParametersValidForAction(edit)) {
      ctx.addIssue({
        code: 'custom',
        path: ['parameters'],
        message: `Invalid parameters for action '${edit.action}', expecting keys: ${Object.keys(actionParameterMap[edit.action].shape).join(', ')}`,
      });
    }
  })
  .meta({ id: 'AssetEditActionItemDto' });

export type AssetEditActionItem = z.infer<typeof __AssetEditActionItemSchema>;
export type AssetEditParameters = AssetEditActionItem['parameters'];

function uniqueEditActions(edits: z.infer<typeof AssetEditActionItemSchema>[]): boolean {
  const keys = new Set<string>();
  for (const edit of edits) {
    const key = edit.action === 'mirror' ? `mirror-${JSON.stringify(edit.parameters)}` : edit.action;
    if (keys.has(key)) {
      return false;
    }
    keys.add(key);
  }
  return true;
}

const AssetEditsCreateSchema = z
  .object({
    edits: z
      .array(AssetEditActionItemSchema)
      .min(1)
      .describe('List of edit actions to apply (crop, rotate, mirror, or mosaic)')
      .refine(uniqueEditActions, { error: 'Duplicate edit actions are not allowed' }),
  })
  .meta({ id: 'AssetEditsCreateDto' });

const AssetEditActionItemResponseSchema = AssetEditActionItemSchema.extend({
  id: z.uuidv4().describe('Asset edit ID'),
}).meta({ id: 'AssetEditActionItemResponseDto' });

const AssetEditsResponseSchema = z
  .object({
    assetId: z.uuidv4().describe('Asset ID these edits belong to'),
    edits: z.array(AssetEditActionItemResponseSchema).describe('List of edit actions applied to the asset'),
  })
  .meta({ id: 'AssetEditsResponseDto' });

export class AssetEditActionItemResponseDto extends createZodDto(AssetEditActionItemResponseSchema) {}
export class AssetEditsCreateDto extends createZodDto(AssetEditsCreateSchema) {}
export class AssetEditsResponseDto extends createZodDto(AssetEditsResponseSchema) {}
export type CropParameters = z.infer<typeof CropParametersSchema>;
export type MosaicParameters = z.infer<typeof MosaicParametersSchema>;
export type MosaicStroke = z.infer<typeof MosaicStrokeSchema>;
