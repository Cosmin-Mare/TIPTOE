/// BLE identifiers from docs/APP_PROTOCOL.md. The handheld advertises as TIPTOE-HH.
library;

const String handheldName = 'TIPTOE-HH';

const String serviceUuid = '7a1e0001-5c1d-4b8e-9f00-7469707430e0';
const String rxUuid = '7a1e0002-5c1d-4b8e-9f00-7469707430e0';
const String txUuid = '7a1e0003-5c1d-4b8e-9f00-7469707430e0';

/// Requested ATT MTU. Notifications are a byte stream, not one frame each.
const int requestMtu = 517;

/// One JSON command per write-with-response.
const int maxCommandBytes = 512;

const int frameTypeJson = 1;
const int frameTypeImage = 2;

/// Parser drops the buffer if a length looks like a desync.
const int maxFrameBytes = 4000000;
