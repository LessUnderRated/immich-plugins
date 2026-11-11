import { MosaicStroke, MosaicStrokeMode } from 'src/dtos/editing.dto.js';
import type { ImageDimensions } from 'src/types.js';

const formatNumber = (value: number) => Number(value.toFixed(2)).toString();

const strokeColor = (mode: MosaicStrokeMode) => (mode === MosaicStrokeMode.Paint ? '#fff' : '#000');

const strokeToSvg = ({ mode, brushSize, points }: MosaicStroke) => {
  const color = strokeColor(mode);

  if (points.length === 1) {
    const [{ x, y }] = points;
    return `<circle cx="${formatNumber(x)}" cy="${formatNumber(y)}" r="${formatNumber(brushSize / 2)}" fill="${color}"/>`;
  }

  const path = points.map(({ x, y }) => `${formatNumber(x)},${formatNumber(y)}`).join(' ');
  return `<polyline points="${path}" fill="none" stroke="${color}" stroke-width="${formatNumber(brushSize)}" stroke-linecap="round" stroke-linejoin="round"/>`;
};

export const buildMosaicMaskSvg = (strokes: MosaicStroke[], { width, height }: ImageDimensions) =>
  [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`,
    `<rect width="${width}" height="${height}" fill="#000"/>`,
    ...strokes.map((stroke) => strokeToSvg(stroke)),
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
