// CRM app request helpers
// Uses getAppPath() + '/' as baseURL

import axios, { type AxiosRequestConfig } from "axios";
import { getAppPath, useAuthStore, isInShell } from "@mochi/web";

// Create a CRM-specific axios instance that uses app path as baseURL
const crmsClient = axios.create({
  timeout: 30000,
  withCredentials: true,
  headers: {
    Accept: "application/json",
    "Content-Type": "application/json",
  },
});

crmsClient.interceptors.request.use((config) => {
  // Always use app path as baseURL (class context)
  config.baseURL = getAppPath() + "/";

  // Remove Content-Type for FormData so axios can set the multipart boundary
  if (config.data instanceof FormData) {
    delete config.headers["Content-Type"];
  }

  // In sandboxed iframe, cookies are unavailable — always use Bearer auth only
  if (isInShell()) {
    config.withCredentials = false;
  }

  // Add auth token
  const token = useAuthStore.getState().token;

  if (token) {
    config.headers.Authorization = token.startsWith("Bearer ")
      ? token
      : `Bearer ${token}`;
  }

  return config;
});

export const crmsRequest = {
  get: async <TResponse>(
    url: string,
    config?: Omit<AxiosRequestConfig, "url" | "method">,
  ): Promise<TResponse> => {
    const response = await crmsClient.get<TResponse>(url, config);
    return response.data;
  },

  post: async <TResponse, TBody = unknown>(
    url: string,
    data?: TBody,
    config?: Omit<AxiosRequestConfig<TBody>, "url" | "method" | "data">,
  ): Promise<TResponse> => {
    const response = await crmsClient.post<TResponse>(url, data, config);
    return response.data;
  },
};
