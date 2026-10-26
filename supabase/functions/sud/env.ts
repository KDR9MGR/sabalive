// Settings from the function's environment (Supabase "secrets"). The dashboard keeps a secret's name exactly as typed, and a name that differs only in capitals
// (SUD_App_Key instead of SUD_APP_KEY) is a different variable to Deno: the function would silently see nothing. So a name is matched ignoring capitals,
// the exact upper-case spelling winning when both exist. Pure, so it is unit-tested without Deno.
export function envValue(all: Record<string, string | undefined>, name: string): string {
  const exact = all[name];
  if (exact !== undefined && exact !== "") return exact;
  const wanted = name.toUpperCase();
  for (const [key, value] of Object.entries(all)) {
    if (key.toUpperCase() === wanted && value !== undefined && value !== "") return value;
  }
  return "";
}
