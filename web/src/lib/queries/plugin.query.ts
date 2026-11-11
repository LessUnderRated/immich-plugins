import { asMutation, queryClient } from '#lib/queries/client.ts';
import {
  installPlugin,
  searchPluginMethods,
  searchPluginTemplates,
  searchPlugins,
  uninstallPlugin,
  type WorkflowTrigger,
} from '@immich/sdk';
import { queryOptions } from '@tanstack/svelte-query';

export const searchPluginsQuery = () =>
  queryOptions({
    queryKey: ['plugins', 'list'],
    queryFn: ({ signal }) => searchPlugins({}, { signal }),
  });

export const searchPluginMethodsQuery = (filter: { trigger?: WorkflowTrigger } = {}) =>
  queryOptions({
    queryKey: ['plugins', 'methods', filter],
    queryFn: ({ signal }) => searchPluginMethods(filter, { signal }),
  });

export const searchPluginTemplatesQuery = () =>
  queryOptions({
    queryKey: ['plugins', 'templates'],
    queryFn: ({ signal }) => searchPluginTemplates({ signal }),
  });

const invalidatePlugins = () => queryClient.invalidateQueries({ queryKey: ['plugins'] });

export const installPluginMutation = () =>
  asMutation(installPlugin, {
    onSuccess: invalidatePlugins,
    meta: { success: { toast: 'plugin_installed' }, error: { toast: 'errors.unable_to_install_plugin' } },
  });

export const uninstallPluginMutation = () =>
  asMutation(uninstallPlugin, {
    onSuccess: invalidatePlugins,
    meta: { success: { toast: 'plugin_uninstalled' }, error: { toast: 'errors.unable_to_uninstall_plugin' } },
  });
