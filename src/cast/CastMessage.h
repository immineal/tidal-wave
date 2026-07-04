#pragma once
#include <QByteArray>
#include <QString>

// Minimal hand-rolled encoder/decoder for the Chromecast CASTV2 `CastMessage`
// protobuf (from Chromium's cast_channel.proto). We only ever send STRING
// payloads, so this covers fields 1-6; unknown fields are skipped on decode.
//
//   field 1  protocol_version  varint  (always 0 = CASTV2_1_0)
//   field 2  source_id         string
//   field 3  destination_id    string
//   field 4  namespace         string
//   field 5  payload_type      varint  (always 0 = STRING)
//   field 6  payload_utf8      string  (JSON text)
//
// On the wire each frame is a 4-byte big-endian length followed by the body;
// framing is handled by CastSession, not here.
struct CastMessage {
    QString sourceId;
    QString destinationId;
    QString ns;         // protobuf field 4 "namespace"
    QString payload;    // field 6 "payload_utf8"

    // Serialize to the protobuf body (no length frame).
    QByteArray encode() const;
    // Parse a protobuf body (no length frame). Returns false on malformed input.
    static bool decode(const QByteArray &body, CastMessage &out);
};
