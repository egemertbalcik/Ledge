#ifndef LEDGE_MEDIA_ADAPTER_H
#define LEDGE_MEDIA_ADAPTER_H

/// The single entry point, installed as a Perl XSUB by the launcher script.
///
/// It takes no arguments on purpose: an XSUB installed through
/// `DynaLoader::dl_install_xsub` is called with Perl's own `(pTHX_ CV *)`,
/// which a plain C function cannot read without linking libperl. Every
/// parameter therefore arrives through the environment instead.
///
/// Reads `LEDGE_ADAPTER_MODE` (`get` or `stream`) and `LEDGE_ADAPTER_ARTWORK`
/// (`1` to include base64 artwork). Writes newline-delimited JSON to stdout.
__attribute__((visibility("default")))
void ledge_media_adapter_main(void);

#endif
