"use client";

import { useCallback, useSyncExternalStore } from "react";

const KEY = "triplex.riskAck.v1";
const EVENT = "triplex:riskAck";

function read(): boolean {
  try {
    return window.localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

function subscribe(cb: () => void) {
  window.addEventListener(EVENT, cb);
  window.addEventListener("storage", cb);
  return () => {
    window.removeEventListener(EVENT, cb);
    window.removeEventListener("storage", cb);
  };
}

/** One-time "I understand the risks" acknowledgement stored in localStorage. */
export function useRiskAck() {
  const acknowledged = useSyncExternalStore(subscribe, read, () => false);
  const acknowledge = useCallback(() => {
    try {
      window.localStorage.setItem(KEY, "1");
    } catch {
      /* storage unavailable: acknowledgement lasts for this page view only */
    }
    window.dispatchEvent(new Event(EVENT));
  }, []);
  return { acknowledged, acknowledge };
}
