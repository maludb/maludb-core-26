/* mc2dbd HTTP layer (libmicrohttpd). R1.0-7. */

#ifndef MC2DBD_HTTP_H
#define MC2DBD_HTTP_H

#include "common.h"

struct MHD_Daemon *http_start(const mc2dbd_config *cfg);
void               http_stop(struct MHD_Daemon *daemon);

#endif
