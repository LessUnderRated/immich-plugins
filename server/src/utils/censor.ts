const SQRT3 = Math.sqrt(3);

export type RawImage = { data: Buffer; width: number; height: number; channels: number };

export const cellHash = (i: number, j: number, salt: number) => {
  let hash = (Math.imul(i, 73_856_093) ^ Math.imul(j, 19_349_663) ^ salt) >>> 0;
  hash = Math.imul(hash ^ (hash >>> 13), 1_274_126_177) >>> 0;
  return ((hash ^ (hash >>> 16)) >>> 0) / 4_294_967_295;
};

export const averagingCell = (size: number) => Math.max(1, Math.floor(size / 2));

const sampler = (averaged: RawImage, cell: number) => (x: number, y: number) => {
  const column = Math.min(averaged.width - 1, Math.max(0, Math.floor(x / cell)));
  const row = Math.min(averaged.height - 1, Math.max(0, Math.floor(y / cell)));
  return (row * averaged.width + column) * averaged.channels;
};

const colorChannels = (channels: number) => (channels >= 3 ? 3 : 1);

export const hexagonCells = (source: RawImage, averaged: RawImage, size: number) => {
  const { width, height, channels } = source;
  const output = Buffer.from(source.data);
  const radius = size / SQRT3;
  const sample = sampler(averaged, averagingCell(size));
  const colors = colorChannels(channels);

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const q = ((SQRT3 / 3) * x - y / 3) / radius;
      const r = ((2 / 3) * y) / radius;
      const s = -q - r;
      let roundedQ = Math.round(q);
      let roundedR = Math.round(r);
      const roundedS = Math.round(s);
      const dq = Math.abs(roundedQ - q);
      const dr = Math.abs(roundedR - r);
      const ds = Math.abs(roundedS - s);
      if (dq > dr && dq > ds) {
        roundedQ = -roundedR - roundedS;
      } else if (dr > ds) {
        roundedR = -roundedQ - roundedS;
      }

      const from = sample(radius * SQRT3 * (roundedQ + roundedR / 2), radius * 1.5 * roundedR);
      const to = (y * width + x) * channels;
      for (let channel = 0; channel < colors; channel++) {
        output[to + channel] = averaged.data[from + channel];
      }
    }
  }

  return output;
};

export const stainedGlassCells = (source: RawImage, averaged: RawImage, size: number) => {
  const { width, height, channels } = source;
  const output = Buffer.from(source.data);
  const sample = sampler(averaged, averagingCell(size));
  const colors = colorChannels(channels);
  const columns = Math.ceil(width / size) + 2;
  const rows = Math.ceil(height / size) + 2;

  const seedX = new Float64Array(columns * rows);
  const seedY = new Float64Array(columns * rows);
  for (let j = 0; j < rows; j++) {
    for (let i = 0; i < columns; i++) {
      seedX[j * columns + i] = (i - 1 + 0.15 + 0.7 * cellHash(i - 1, j - 1, 1)) * size;
      seedY[j * columns + i] = (j - 1 + 0.15 + 0.7 * cellHash(i - 1, j - 1, 2)) * size;
    }
  }

  for (let y = 0; y < height; y++) {
    const cellRow = Math.floor(y / size) + 1;
    for (let x = 0; x < width; x++) {
      const cellColumn = Math.floor(x / size) + 1;
      let nearest = Infinity;
      let nearestIndex = 0;
      for (let dj = -1; dj <= 1; dj++) {
        for (let di = -1; di <= 1; di++) {
          const index = (cellRow + dj) * columns + cellColumn + di;
          const distance = (seedX[index] - x) ** 2 + (seedY[index] - y) ** 2;
          if (distance >= nearest) {
            continue;
          }
          nearest = distance;
          nearestIndex = index;
        }
      }

      const to = (y * width + x) * channels;
      const from = sample(seedX[nearestIndex], seedY[nearestIndex]);
      for (let channel = 0; channel < colors; channel++) {
        output[to + channel] = averaged.data[from + channel];
      }
    }
  }

  return output;
};
