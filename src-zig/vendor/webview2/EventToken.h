/* The one type WebView2.h needs from the Windows SDK's EventToken.h (missing from mingw-w64). */
#pragma once
typedef struct EventRegistrationToken { __int64 value; } EventRegistrationToken;
