import { cellHash } from 'src/utils/censor.js';

describe('cellHash', () => {
  it('should match the values the mobile app uses', () => {
    expect(cellHash(0, 0, 1)).toBeCloseTo(0.296658787945, 12);
    expect(cellHash(3, 7, 2)).toBeCloseTo(0.641872804063, 12);
    expect(cellHash(-1, 5, 1)).toBeCloseTo(0.450154620793, 12);
    expect(cellHash(120, 45, 2)).toBeCloseTo(0.909014901824, 12);
  });
});
