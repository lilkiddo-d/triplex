"use client";

import { useRiskAck } from "@/hooks/useRiskAck";

export function RiskAckBox() {
  const { acknowledged, acknowledge } = useRiskAck();
  return (
    <div className="card mt-8 border-brand-500/40">
      {acknowledged ? (
        <p className="text-sm text-emerald-300">
          You have acknowledged these risks on this device. Minting is enabled.
        </p>
      ) : (
        <>
          <p className="text-sm text-zinc-300">
            By continuing you confirm that you have read and understood this disclosure, that you are not a person in a
            restricted jurisdiction, and that you accept you may lose your entire investment.
          </p>
          <button className="btn btn-primary mt-3" onClick={acknowledge}>
            I understand the risks
          </button>
        </>
      )}
    </div>
  );
}
