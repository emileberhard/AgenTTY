declare module "qrcode-terminal" {
  interface GenerateOptions {
    readonly small?: boolean;
  }

  interface QRCodeTerminal {
    generate(
      input: string,
      options: GenerateOptions,
      callback: (output: string) => void
    ): void;
  }

  const qrcode: QRCodeTerminal;
  export default qrcode;
}
