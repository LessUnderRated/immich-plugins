import type {
  AssetTypeEnum,
  AssetVisibility,
  TagResponseDto,
  WorkflowType,
} from '@immich/sdk';

type DeepPartial<T> = T extends Date
  ? T
  : T extends Record<string, unknown>
    ? { [K in keyof T]?: DeepPartial<T[K]> }
    : T extends Array<infer R>
      ? DeepPartial<R>[]
      : T;

export const GalleryViewV1 = 'GalleryViewV1' as const;

/** Event types a plugin method can declare: server workflow types plus app-only hooks. */
export type PluginEventType = WorkflowType | typeof GalleryViewV1;

export type WorkflowEventMap = {
  [WorkflowType.AssetV1]: AssetV1;
  [GalleryViewV1]: GalleryViewV1Data;
  // [WorkflowType.AssetPersonV1]: AssetPersonV1;
} & { [K in PluginEventType]: unknown };

export type WorkflowEventData<T extends PluginEventType> = WorkflowEventMap[T];

/** Input of a GalleryViewV1 method: called once per settings change, never per photo. */
export type GalleryViewV1Data = {
  scope: 'main' | 'album';
  albumId?: string;
  albums: { id: string; name: string }[];
};

/** How the gallery should be sorted and filtered; the app turns this into a database query. */
export type GalleryViewSpec = {
  sort?: {
    field: 'createdAt' | 'updatedAt' | 'name' | 'pixels' | 'duration';
    direction: 'asc' | 'desc';
  };
  include?: { photos?: boolean; videos?: boolean; gifs?: boolean };
  /** Hidden from the main gallery; ignored inside an album. */
  excludeAlbumIds?: string[];
};

export enum WorkflowTrigger {
  AssetCreate = 'AssetCreate',
  AssetMetadataExtraction = 'AssetMetadataExtraction',
  AssetOcrExtraction = 'AssetOcrExtraction',
  AssetTagged = 'AssetTagged',
  // PersonRecognized = 'PersonRecognized',
}

export type WorkflowEventPayload<
  T extends PluginEventType,
  TConfig = WorkflowStepConfig,
> = {
  trigger: WorkflowTrigger;
  type: T;
  data: WorkflowEventData<T>;
  config: TConfig;
  workflow: {
    id: string;
    authToken: string;
    stepId: string;
    debug?: boolean;
  };
};

export type WorkflowChanges<T extends PluginEventType> = DeepPartial<
  WorkflowEventData<T>
>;

export type WorkflowResponse<T extends PluginEventType> = {
  /** GalleryViewV1 methods return the view to apply */
  view?: GalleryViewSpec;
  workflow?: {
    /** stop the workflow */
    continue?: boolean;
  };
  changes?: WorkflowChanges<T>;
  /** data to be passed to the next workflow step */
  data?: Record<string, unknown>;
  /** update step config */
  config?: WorkflowStepConfig;
};

export type WorkflowStepConfig = {
  [key: string]: ConfigValue;
};

export type ConfigValue =
  | string
  | number
  | boolean
  | null
  | ConfigValue[]
  | { [key: string]: ConfigValue };

export type AssetV1 = {
  asset: {
    id: string;
    ownerId: string;
    type: AssetTypeEnum;
    originalPath: string;
    fileCreatedAt: string;
    fileModifiedAt: string;
    isFavorite: boolean;
    checksum: Buffer; // sha1 checksum
    livePhotoVideoId: string | null;
    updatedAt: string;
    createdAt: string;
    originalFileName: string;
    isOffline: boolean;
    libraryId: string | null;
    isExternal: boolean;
    deletedAt: string | null;
    localDateTime: string;
    stackId: string | null;
    duplicateId: string | null;
    visibility: AssetVisibility;
    isEdited: boolean;
    tags: TagResponseDto[];
    exifInfo: {
      make: string | null;
      model: string | null;
      exifImageWidth: number | null;
      exifImageHeight: number | null;
      fileSizeInByte: number | null;
      orientation: string | null;
      dateTimeOriginal: string | null;
      modifyDate: string | null;
      lensModel: string | null;
      fNumber: number | null;
      focalLength: number | null;
      iso: number | null;
      latitude: number | null;
      longitude: number | null;
      city: string | null;
      state: string | null;
      country: string | null;
      description: string | null;
      fps: number | null;
      exposureTime: string | null;
      livePhotoCID: string | null;
      timeZone: string | null;
      projectionType: string | null;
      profileDescription: string | null;
      colorspace: string | null;
      bitsPerSample: number | null;
      autoStackId: string | null;
      rating: number | null;
      tags: string[] | null;
      updatedAt: string | null;
    } | null;
    ocr?: {
      text: string;
      textScore: number;
      boxScore: number;
    }[]
  };
};

// export type AssetPersonV1 = AssetV1 & {
//   person: {
//     id: string;
//     name: string;
//   };
// };
