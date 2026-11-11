import { MosaicStroke, MosaicStrokeMode, MosaicStyle } from 'src/dtos/editing.dto.js';
import type { ImageDimensions } from 'src/types.js';

const formatNumber = (value: number) => Number(value.toFixed(2)).toString();

export const strokeBlockSize = (stroke: MosaicStroke, defaultBlockSize: number) => stroke.blockSize ?? defaultBlockSize;

export type CensorEffect = { style: MosaicStyle; size: number };

export const strokeEffect = (stroke: MosaicStroke, defaultBlockSize: number): CensorEffect => ({
  style: stroke.style ?? MosaicStyle.Pixelate,
  size: strokeBlockSize(stroke, defaultBlockSize),
});

export const paintedEffects = (strokes: MosaicStroke[], defaultBlockSize: number): CensorEffect[] => {
  const effects = new Map<string, CensorEffect>();
  for (const stroke of strokes) {
    if (stroke.mode !== MosaicStrokeMode.Paint) {
      continue;
    }
    const effect = strokeEffect(stroke, defaultBlockSize);
    effects.set(`${effect.style}:${effect.size}`, effect);
  }
  return effects.values().toArray();
};

const strokeToSvg = ({ brushSize, points }: MosaicStroke, color: string) => {
  if (points.length === 1) {
    const [{ x, y }] = points;
    return `<circle cx="${formatNumber(x)}" cy="${formatNumber(y)}" r="${formatNumber(brushSize / 2)}" fill="${color}"/>`;
  }

  const path = points.map(({ x, y }) => `${formatNumber(x)},${formatNumber(y)}`).join(' ');
  return `<polyline points="${path}" fill="none" stroke="${color}" stroke-width="${formatNumber(brushSize)}" stroke-linecap="round" stroke-linejoin="round"/>`;
};

export const buildMosaicMaskSvg = (
  strokes: MosaicStroke[],
  { width, height }: ImageDimensions,
  isVisible: (stroke: MosaicStroke) => boolean = (stroke) => stroke.mode === MosaicStrokeMode.Paint,
) =>
  [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`,
    `<rect width="${width}" height="${height}" fill="#000"/>`,
    ...strokes.map((stroke) => strokeToSvg(stroke, isVisible(stroke) ? '#fff' : '#000')),
    '</svg>',
  ].join('');

export const blendWithMask = (original: Buffer, pixelated: Buffer, mask: Buffer, channels: number) => {
  const output = Buffer.from(original);
  for (let pixel = 0; pixel < mask.length; pixel++) {
    const weight = mask[pixel];
    if (weight === 0) {
      continue;
    }

    const offset = pixel * channels;
    for (let channel = 0; channel < channels; channel++) {
      const index = offset + channel;
      output[index] = Math.round(original[index] + ((pixelated[index] - original[index]) * weight) / 255);
    }
  }

  return output;
};
