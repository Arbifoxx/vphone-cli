#pragma once

// Process-local entry points also used by the on-device integration probe.
// Install after creating a Metal device in a probe; NULL uses the guest cache
// directory. Returned JSON is malloc-owned. Flush is for tests/shutdown only.
int vphone_pipeline_archive_install(const char *cacheRoot);
void vphone_pipeline_archive_prewarm(void);
void vphone_pipeline_archive_flush(void);
char *vphone_pipeline_archive_copy_statistics(void);
