// Browser-side owner session guard. This is a convenience for the owner, not the security boundary:
// the data is protected by database rules (RLS), which only answer for the registered owner.

export const LOGIN_PATH = '/admin/login';

type Client = Awaited<typeof import('./supabase')>['supabase'];

export async function getClient(): Promise<Client> {
  const { supabase } = await import('./supabase');
  return supabase;
}

/** True only if someone is signed in AND the database recognises them as the owner. */
export async function isOwner(supabase: Client): Promise<boolean> {
  const { data } = await supabase.auth.getSession();
  if (!data.session) return false;
  const { data: ok, error } = await supabase.rpc('is_platform_admin');
  return !error && ok === true;
}

/**
 * Run on every private page. Shows the page only for the owner, otherwise signs out and goes to login.
 * Returns the client when the owner is confirmed, or null after redirecting.
 */
export async function requireOwner(): Promise<Client | null> {
  const supabase = await getClient();
  if (await isOwner(supabase)) {
    document.documentElement.dataset.auth = 'ready';
    supabase.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT') location.replace(LOGIN_PATH);
    });
    return supabase;
  }
  await supabase.auth.signOut();
  location.replace(LOGIN_PATH);
  return null;
}
