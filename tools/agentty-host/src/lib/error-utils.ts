export function isCodeError(
  error: unknown,
  expectedCode: string
): error is Error & {
  readonly code: string;
} {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string" &&
    error.code === expectedCode
  );
}

export function stdoutFromError(error: unknown): string {
  return (
    typeof error === "object" &&
    error !== null &&
    "stdout" in error &&
    typeof error.stdout === "string"
  )
    ? error.stdout
    : "";
}
