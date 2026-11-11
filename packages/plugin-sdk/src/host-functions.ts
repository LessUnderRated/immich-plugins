import {
  getAllAlbums,
  type AlbumResponseDto,
  type AssetEditActionItemDto,
  type AssetEditsResponseDto,
  type BulkIdResponseDto,
  type BulkIdsDto,
  type CreateAlbumDto,
  type TagBulkAssetsDto,
  type TagBulkAssetsResponseDto,
} from '@immich/sdk';
import type { AssetV1 } from 'src/types.js';

declare module 'extism:host' {
  interface user extends Record<
    (typeof availableFunctions)[number],
    (ptr: PTR) => I64
  > {}
}

type AlbumsToAssets = {
  assetIds: string[];
  albumIds: string[];
};

type HostFunctionSuccessResult<T> = { success: true; response: T };
type HostFunctionErrorResult = {
  success: false;
  status: number;
  message: string;
};
type HostFunctionResult<T> =
  HostFunctionSuccessResult<T> | HostFunctionErrorResult;

type QueryParams<T extends (...args: any) => any> = Parameters<T>[0];
type AlbumSearchDto = QueryParams<typeof getAllAlbums>;
type HttpRequestOptions = {
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  /** binary request body, base64 encoded */
  bodyBase64?: string;
  /** 'base64' returns the response body base64 encoded */
  responseType?: 'text' | 'base64';
  timeoutSeconds?: number;
};
type HttpResponse = {
  ok: string;
  status: number;
  headers?: Record<string, string>;
  body: string;
};
export type ListAssetsOptions = {
  offset?: number;
  limit?: number;
  albumId?: string;
};
export type PixelImage = {
  assetId?: string;
  width: number;
  height: number;
  rgba: string;
};
export type WriteImageInput =
  { width: number; height: number; rgba: string } | { encoded: string };
export type WriteImageResult = {
  assetId: string;
  outcome: string;
  createdId: string | null;
};
export type FileContents = { path: string; size: number; base64: string };
export type WriteFileOptions = {
  text?: string;
  base64?: string;
  append?: boolean;
};
export type FileEntry = {
  path: string;
  name: string;
  isDirectory: boolean;
  size: number;
};

export const availableFunctions = [
  'searchAlbums',
  'createAlbum',
  'addAssetsToAlbum',
  'addAssetsToAlbums',
  'httpRequest',
  'bulkTagAssets',
  'getAssetEdits',
  'editAsset',
  'removeAssetEdits',
  'listAssets',
  'getAsset',
  'readImage',
  'writeImage',
  'readFile',
  'writeFile',
  'listFiles',
  'deleteFile',
  'getStorage',
  'setStorage',
] as const;

export const hostFunctions = (authToken: string) => {
  const host = Host.getFunctions();
  type HostFunctionName = keyof typeof host;

  const call = <T, R>(name: HostFunctionName, authToken: string, args: T) => {
    const pointer1 = Memory.fromString(JSON.stringify({ authToken, args }));
    const fn = host[name];
    const handler = Memory.find(fn(pointer1.offset));

    try {
      const result = JSON.parse(handler.readString()) as HostFunctionResult<R>;

      if (result.success) {
        return result.response;
      }

      throw new Error(
        `Failed to call host function "${String(name)}", received ${result.status} - ${JSON.stringify(result.message)}`,
      );
    } finally {
      handler.free();
      pointer1.free();
    }
  };

  return {
    // album
    searchAlbums: (dto: AlbumSearchDto) =>
      call<[AlbumSearchDto], AlbumResponseDto[]>('searchAlbums', authToken, [
        dto,
      ]),
    createAlbum: (dto: CreateAlbumDto) =>
      call<[CreateAlbumDto], AlbumResponseDto>('createAlbum', authToken, [dto]),
    addAssetsToAlbum: (albumId: string, assetIds: string[]) =>
      call<[string, BulkIdsDto], BulkIdResponseDto[]>(
        'addAssetsToAlbum',
        authToken,
        [albumId, { ids: assetIds }],
      ),
    addAssetsToAlbums: ({ assetIds, albumIds }: AlbumsToAssets) =>
      call('addAssetsToAlbums', authToken, [{ albumIds, assetIds }]),
    httpRequest: (url: string, options?: HttpRequestOptions) =>
      call<[string, HttpRequestOptions | undefined], HttpResponse>(
        'httpRequest',
        authToken,
        [url, options],
      ),
    bulkTagAssets: (dto: TagBulkAssetsDto) =>
      call<[TagBulkAssetsDto], TagBulkAssetsResponseDto>(
        'bulkTagAssets',
        authToken,
        [dto],
      ),
    // image editing
    /** Current non-destructive edits (crop, rotate, mirror) on an asset. */
    getAssetEdits: (assetId: string) =>
      call<[string], AssetEditsResponseDto>('getAssetEdits', authToken, [
        assetId,
      ]),
    /**
     * Replace ALL edits on an image asset and regenerate its thumbnails. Pass the full list you want applied
     * (read the current list with getAssetEdits to keep existing ones). Crop must come first; each action once
     * (mirror once per axis). Throws for videos, live photos, panoramas, GIF and SVG.
     */
    editAsset: (assetId: string, edits: AssetEditActionItemDto[]) =>
      call<
        [string, { edits: AssetEditActionItemDto[] }],
        AssetEditsResponseDto
      >('editAsset', authToken, [assetId, { edits }]),
    /** Remove all edits from an asset, restoring the original. */
    removeAssetEdits: (assetId: string) =>
      call<[string], void>('removeAssetEdits', authToken, [assetId]),
    // device only: assets, pixels, files and storage
    /** List assets, newest first, optionally from one album (device folder or app album). */
    listAssets: (options: ListAssetsOptions = {}) =>
      call<[ListAssetsOptions], AssetV1['asset'][]>('listAssets', authToken, [
        options,
      ]),
    getAsset: (assetId: string) =>
      call<[string], AssetV1['asset']>('getAsset', authToken, [assetId]),
    /** Decode an image to RGBA (base64). Use maxSize to downscale; original reads the unedited file. */
    readImage: (
      assetId: string,
      options: { maxSize?: number; original?: boolean } = {},
    ) =>
      call<[string, { maxSize?: number; original?: boolean }], PixelImage>(
        'readImage',
        authToken,
        [assetId, options],
      ),
    /** Replace the image's pixels (RGBA or an encoded file). The original is backed up first. */
    writeImage: (assetId: string, image: WriteImageInput) =>
      call<[string, WriteImageInput], WriteImageResult>(
        'writeImage',
        authToken,
        [assetId, image],
      ),
    /** Paths are relative to the plugin's data folder unless absolute. */
    readFile: (path: string) =>
      call<[string], FileContents>('readFile', authToken, [path]),
    writeFile: (path: string, options: WriteFileOptions) =>
      call<[string, WriteFileOptions], { path: string; size: number }>(
        'writeFile',
        authToken,
        [path, options],
      ),
    listFiles: (path = '') =>
      call<[string], FileEntry[]>('listFiles', authToken, [path]),
    deleteFile: (path: string) =>
      call<[string], void>('deleteFile', authToken, [path]),
    /** Per-plugin storage. getStorage('') returns everything. setStorage(key, null) deletes. */
    getStorage: <T = unknown>(key: string) =>
      call<[string], T>('getStorage', authToken, [key]),
    setStorage: (key: string, value: unknown) =>
      call<[string, unknown], void>('setStorage', authToken, [key, value]),
  } satisfies Record<(typeof availableFunctions)[number], unknown>;
};
