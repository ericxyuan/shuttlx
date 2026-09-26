import { pageAccount } from '@/lib/server';
import PairClaim from './pair-claim';
export const dynamic = 'force-dynamic';
export default async function PairPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const query = await searchParams;
  const device = typeof query.device === 'string' ? query.device : '';
  const nonce = typeof query.nonce === 'string' ? query.nonce : '';
  const name = typeof query.name === 'string' ? query.name : 'Apple Watch';
  const account = await pageAccount();
  const returnTo = `/pair?device=${encodeURIComponent(device)}&nonce=${encodeURIComponent(nonce)}&name=${encodeURIComponent(name)}`;
  return <PairClaim signedIn={!!account} deviceID={device} nonce={nonce} name={name} signInHref={`/api/auth/apple/start?return_to=${encodeURIComponent(returnTo)}`} />;
}
