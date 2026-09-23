#include "protocol.h"
#include <string.h>
#include "mbedtls/gcm.h"

namespace proto {

static void make_nonce(uint8_t dir, uint8_t node, uint32_t ctr, uint8_t nonce[12]) {
  memset(nonce, 0, 12);
  nonce[0] = dir;
  nonce[1] = node;
  nonce[8] = ctr & 0xFF;
  nonce[9] = (ctr >> 8) & 0xFF;
  nonce[10] = (ctr >> 16) & 0xFF;
  nonce[11] = (ctr >> 24) & 0xFF;
}

size_t seal(const uint8_t key[16], uint8_t dir, uint8_t node, uint8_t type, uint32_t ctr,
            const uint8_t* payload, size_t len, uint8_t* out) {
  if (len > MAX_PAYLOAD) return 0;
  Header h{VERSION, node, type, ctr};
  memcpy(out, &h, HDR_LEN);
  uint8_t nonce[12];
  make_nonce(dir, node, ctr, nonce);

  mbedtls_gcm_context gcm;
  mbedtls_gcm_init(&gcm);
  int rc = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 128);
  if (rc == 0) {
    rc = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, len, nonce, sizeof(nonce), out, HDR_LEN,
                                   payload, out + HDR_LEN, TAG_LEN, out + HDR_LEN + len);
  }
  mbedtls_gcm_free(&gcm);
  return rc == 0 ? HDR_LEN + len + TAG_LEN : 0;
}

int open(const uint8_t key[16], uint8_t dir, const uint8_t* frame, size_t frame_len, Header& hdr,
         uint8_t* payload) {
  if (frame_len < HDR_LEN + TAG_LEN || frame_len > MAX_FRAME) return -1;
  memcpy(&hdr, frame, HDR_LEN);
  if (hdr.ver != VERSION) return -1;
  size_t len = frame_len - HDR_LEN - TAG_LEN;
  uint8_t nonce[12];
  make_nonce(dir, hdr.node, hdr.ctr, nonce);

  mbedtls_gcm_context gcm;
  mbedtls_gcm_init(&gcm);
  int rc = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 128);
  if (rc == 0) {
    rc = mbedtls_gcm_auth_decrypt(&gcm, len, nonce, sizeof(nonce), frame, HDR_LEN, frame + HDR_LEN + len,
                                  TAG_LEN, frame + HDR_LEN, payload);
  }
  mbedtls_gcm_free(&gcm);
  return rc == 0 ? (int)len : -2;
}

}  // namespace proto
