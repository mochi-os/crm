// Mochi CRMs: WebSocket hook for real-time crm updates
// Copyright Alistair Cunningham 2026

import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";

interface CrmWebsocketEvent {
  type: string;
  crm: string;
  object?: string;
  id?: string;
  source?: string;
  target?: string;
}

const RECONNECT_DELAY = 3000;

function getWebSocketUrl(key: string): string {
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}/_/websocket?key=${key}`;
}

// Singleton WebSocket manager to prevent duplicate connections
class WebSocketManager {
  private connections = new Map<string, WebSocket>();
  private reconnectTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private subscribers = new Map<
    string,
    Set<(event: CrmWebsocketEvent) => void>
  >();
  private connectionAttempts = new Map<string, boolean>();

  subscribe(
    key: string,
    callback: (event: CrmWebsocketEvent) => void,
  ): () => void {
    if (!this.subscribers.has(key)) {
      this.subscribers.set(key, new Set());
    }
    this.subscribers.get(key)!.add(callback);
    this.ensureConnection(key);

    return () => {
      const subs = this.subscribers.get(key);
      if (subs) {
        subs.delete(callback);
        if (subs.size === 0) {
          this.subscribers.delete(key);
          this.closeConnection(key);
        }
      }
    };
  }

  private ensureConnection(key: string) {
    const existing = this.connections.get(key);
    if (
      existing &&
      (existing.readyState === WebSocket.OPEN ||
        existing.readyState === WebSocket.CONNECTING)
    ) {
      return;
    }
    if (this.connectionAttempts.get(key)) return;
    this.connect(key);
  }

  private connect(key: string) {
    const timer = this.reconnectTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.reconnectTimers.delete(key);
    }
    if (!this.subscribers.has(key) || this.subscribers.get(key)!.size === 0) {
      return;
    }

    this.connectionAttempts.set(key, true);

    try {
      const ws = new WebSocket(getWebSocketUrl(key));
      this.connections.set(key, ws);

      ws.onopen = () => {
        this.connectionAttempts.set(key, false);
      };

      ws.onmessage = (event) => {
        try {
          const data: CrmWebsocketEvent = JSON.parse(event.data);
          const subs = this.subscribers.get(key);
          if (subs) {
            subs.forEach((callback) => callback(data));
          }
        } catch {
          // Ignore parse errors
        }
      };

      ws.onclose = () => {
        this.connectionAttempts.set(key, false);
        this.connections.delete(key);
        if (
          this.subscribers.has(key) &&
          this.subscribers.get(key)!.size > 0
        ) {
          const t = setTimeout(() => this.connect(key), RECONNECT_DELAY);
          this.reconnectTimers.set(key, t);
        }
      };

      ws.onerror = () => {
        this.connectionAttempts.set(key, false);
      };
    } catch {
      this.connectionAttempts.set(key, false);
      if (
        this.subscribers.has(key) &&
        this.subscribers.get(key)!.size > 0
      ) {
        const t = setTimeout(() => this.connect(key), RECONNECT_DELAY);
        this.reconnectTimers.set(key, t);
      }
    }
  }

  private closeConnection(key: string) {
    const timer = this.reconnectTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.reconnectTimers.delete(key);
    }
    const ws = this.connections.get(key);
    if (ws) {
      ws.close();
      this.connections.delete(key);
    }
    this.connectionAttempts.delete(key);
  }
}

const wsManager = new WebSocketManager();

// Subscribe to crm WebSocket events and invalidate relevant queries
export function useCrmWebsocket(crmFingerprint?: string) {
  const queryClient = useQueryClient();

  useEffect(() => {
    if (!crmFingerprint) return;

    const handleMessage = (data: CrmWebsocketEvent) => {
      const pid = crmFingerprint;
      switch (data.type) {
        case "comment/create":
        case "comment/update":
        case "comment/delete":
          if (data.object) {
            void queryClient.invalidateQueries({
              queryKey: ["comments", pid, data.object],
            });
            void queryClient.invalidateQueries({
              queryKey: ["object", pid, data.object],
            });
          }
          break;
        case "object/create":
        case "object/update":
        case "object/delete":
          void queryClient.invalidateQueries({
            queryKey: ["objects", pid],
          });
          if (data.id) {
            void queryClient.invalidateQueries({
              queryKey: ["object", pid, data.id],
            });
          }
          break;
        case "values/update":
          if (data.id) {
            void queryClient.invalidateQueries({
              queryKey: ["object", pid, data.id],
            });
          }
          void queryClient.invalidateQueries({
            queryKey: ["objects", pid],
          });
          break;
        case "link/create":
        case "link/delete":
          if (data.source) {
            void queryClient.invalidateQueries({
              queryKey: ["object", pid, data.source],
            });
          }
          if (data.target) {
            void queryClient.invalidateQueries({
              queryKey: ["object", pid, data.target],
            });
          }
          break;
        case "attachment/add":
        case "attachment/remove":
          if (data.object) {
            void queryClient.invalidateQueries({
              queryKey: ["attachments", pid, data.object],
            });
          }
          break;
        case "crm/update":
          void queryClient.invalidateQueries({
            queryKey: ["crm", pid],
          });
          break;
        case "class/create":
        case "class/update":
        case "class/delete":
        case "field/create":
        case "field/update":
        case "field/delete":
        case "field/reorder":
        case "option/create":
        case "option/update":
        case "option/delete":
        case "option/reorder":
        case "view/create":
        case "view/update":
        case "view/delete":
        case "view/reorder":
        case "hierarchy/set":
          void queryClient.invalidateQueries({
            queryKey: ["crm", pid],
          });
          break;
      }
    };

    return wsManager.subscribe(crmFingerprint, handleMessage);
  }, [crmFingerprint, queryClient]);
}
