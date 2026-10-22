export function isTailscaleMagicDNSHostname(value: string): boolean {
  const normalized = value.toLowerCase();
  return normalized.endsWith(".ts.net") && normalized.includes(".");
}

export function isLocalDomainHostname(value: string): boolean {
  return value.endsWith(".local") || value.endsWith(".localdomain");
}

export function isFQDN(value: string): boolean {
  return value.includes(".");
}

export function normalizeMagicDNSName(value: string | undefined): string | null {
  const normalized = value?.trim();
  if (!normalized) {
    return null;
  }

  return normalized.endsWith(".") ? normalized.slice(0, -1) : normalized;
}

export function preferredMagicDNSHostname(magicDNSName: string | null): string | null {
  if (!magicDNSName) {
    return null;
  }

  if (!isTailscaleMagicDNSHostname(magicDNSName)) {
    return magicDNSName;
  }

  const [firstLabel] = magicDNSName.split(".", 1);
  return firstLabel?.trim() || magicDNSName;
}
