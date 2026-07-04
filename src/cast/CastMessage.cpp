#include "CastMessage.h"

namespace {

void putVarint(QByteArray &out, quint64 v) {
    do {
        quint8 b = v & 0x7F;
        v >>= 7;
        if (v) b |= 0x80;
        out.append(char(b));
    } while (v);
}

void putVarintField(QByteArray &out, int field, quint64 v) {
    putVarint(out, (quint64(field) << 3) | 0);   // wire type 0 (varint)
    putVarint(out, v);
}

void putStringField(QByteArray &out, int field, const QByteArray &s) {
    putVarint(out, (quint64(field) << 3) | 2);   // wire type 2 (length-delimited)
    putVarint(out, quint64(s.size()));
    out.append(s);
}

bool getVarint(const QByteArray &in, int &pos, quint64 &v) {
    v = 0;
    int shift = 0;
    while (pos < in.size()) {
        quint8 b = quint8(in.at(pos++));
        v |= quint64(b & 0x7F) << shift;
        if (!(b & 0x80)) return true;
        shift += 7;
        if (shift > 63) return false;
    }
    return false;
}

} // namespace

QByteArray CastMessage::encode() const {
    QByteArray out;
    putVarintField(out, 1, 0);                       // protocol_version = CASTV2_1_0
    putStringField(out, 2, sourceId.toUtf8());
    putStringField(out, 3, destinationId.toUtf8());
    putStringField(out, 4, ns.toUtf8());
    putVarintField(out, 5, 0);                       // payload_type = STRING
    putStringField(out, 6, payload.toUtf8());
    return out;
}

bool CastMessage::decode(const QByteArray &body, CastMessage &out) {
    int pos = 0;
    while (pos < body.size()) {
        quint64 tag;
        if (!getVarint(body, pos, tag)) return false;
        const int field = int(tag >> 3);
        const int wire  = int(tag & 0x7);
        switch (wire) {
            case 0: {                                // varint
                quint64 v;
                if (!getVarint(body, pos, v)) return false;
                break;
            }
            case 2: {                                // length-delimited
                quint64 len;
                if (!getVarint(body, pos, len)) return false;
                if (len > quint64(body.size() - pos)) return false;
                const QByteArray data = body.mid(pos, int(len));
                pos += int(len);
                switch (field) {
                    case 2: out.sourceId      = QString::fromUtf8(data); break;
                    case 3: out.destinationId = QString::fromUtf8(data); break;
                    case 4: out.ns            = QString::fromUtf8(data); break;
                    case 6: out.payload       = QString::fromUtf8(data); break;
                    default: break;
                }
                break;
            }
            case 5: pos += 4; break;                 // 32-bit
            case 1: pos += 8; break;                 // 64-bit
            default: return false;                   // groups / unsupported
        }
    }
    return true;
}
