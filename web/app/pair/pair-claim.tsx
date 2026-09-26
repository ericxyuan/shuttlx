'use client';
import { useState } from 'react';
export default function PairClaim({ signedIn, deviceID, nonce, name, signInHref }: { signedIn: boolean; deviceID: string; nonce: string; name: string; signInHref: string }) {
  const [status, setStatus] = useState(signedIn ? 'Ready to connect this Watch.' : 'Sign in with Apple to connect this Watch to your account.');
  const [busy, setBusy] = useState(false);
  async function claim() {
    setBusy(true); setStatus('Connecting your Watch…');
    try {
      const response = await fetch('/api/device/qr/claim', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ deviceID, nonce, name }) });
      const data = await response.json() as { error?: string; redirect?: string };
      if (!response.ok || !data.redirect) throw new Error(data.error ?? 'The Watch could not be connected.');
      setStatus('Connected. Return to ShuttlX on your iPhone to finish sending the credential to your Watch.');
      window.location.href = data.redirect;
    } catch (error) { setStatus(error instanceof Error ? error.message : 'The Watch could not be connected.'); setBusy(false); }
  }
  return <main className="auth-shell"><div className="auth-card"><img src="/master-icon.png" alt=""/><p className="eyebrow">SHUTTLX WATCH</p><h1>Connect {name}</h1><p>{status}</p>{signedIn ? <button className="primary block" disabled={busy} onClick={() => void claim()}>{busy ? 'Connecting…' : 'Connect this Watch'}</button> : <a className="primary block" href={signInHref}>Sign in with Apple</a>}<p className="footnote">This one-time QR request expires quickly and can only be used once. Your sessions remain isolated to your signed-in account.</p></div></main>;
}
