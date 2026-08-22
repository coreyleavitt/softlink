/* RFC 0011 S0a item 5, story (f): links against missing_dep.dll (see
 * missing_dep.c) at build time, via its import library. missing_dep.dll is
 * deleted post-link, leaving victim.dll present on disk but with an
 * import-table entry that cannot resolve at LoadLibrary time — the
 * plausible partial-bundle failure the RFC calls out. */
__declspec(dllimport) int missing_dep_func(void);

__declspec(dllexport) int victim_func(void) {
  return missing_dep_func();
}
