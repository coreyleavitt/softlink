/* RFC 0011 S0a item 5, story (c): a dependency library that libhasdep.so
 * links against at build time. Deleted before the test suite runs, so
 * libhasdep.so's own DT_NEEDED entry for it can never resolve at runtime —
 * the Linux analogue of a partial-bundle missing transitive dependency. */
int stubdep_func(void) {
  return 1;
}
