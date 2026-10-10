// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QByteArray>
#include <QString>

// Hand-rolled encoder/decoder for the CASTV2 `CastMessage` protobuf (Chromium's
// cast_channel.proto). Only STRING payloads are sent, so it covers fields 1-6;
// unknown fields are skipped on decode. Framing is CastSession's job.
struct CastMessage {
    QString sourceId;         // field 2 "source_id"
    QString destinationId;    // field 3 "destination_id"
    QString ns;         // protobuf field 4 "namespace"
    QString payload;    // field 6 "payload_utf8"

    // Serialize to the protobuf body (no length frame).
    QByteArray encode() const;
    // Parse a protobuf body (no length frame). Returns false on malformed input.
    static bool decode(const QByteArray &body, CastMessage &out);
};
