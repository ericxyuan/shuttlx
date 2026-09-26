import ShuttlWeb from './shuttl-web';
import { pageAccount } from '@/lib/server';
export const dynamic = 'force-dynamic';
export default async function Home() {
  const user = await pageAccount();
  return <ShuttlWeb signedIn={!!user} />;
}
