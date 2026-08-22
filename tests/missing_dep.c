/* RFC 0011 S0a item 5, story (f): Windows measurement leg fixture.
 * victim.dll links against this at build time; missing_dep.dll is deleted
 * afterward, leaving victim.dll with an unresolvable import. */
__declspec(dllexport) int missing_dep_func(void) {
  return 1;
}
