// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <QList>
#include <QtGlobal>
#include <QSet>
#include <QString>

#include <functional>
#include <memory>

// Pages a list endpoint and hands the whole list over at once. `done` gets the
// list and whether it is whole: an error keeps what arrived and answers false.
// A run also ends on an empty page, a page that added nothing new (a server
// ignoring `offset`) or, with `shortPageEnds`, a short page. The page cap ends
// it too, and answers false.
template <typename T, typename Fetch, typename KeyOf, typename Done>
void pageEverything(Fetch fetch, KeyOf keyOf, Done done, int limit, int maxPages,
                    bool shortPageEnds = true) {
    struct Run {
        QList<T>      acc;
        QSet<QString> seen;
        int offset = 0;
        int pages  = 0;
        std::function<void()> step;
    };

    auto run = std::make_shared<Run>();
    // The step holds a weak reference to its own state, so the only strong
    // references are the in-flight reply callbacks. The chain frees itself
    // when the last one has run.
    std::weak_ptr<Run> weak = run;
    run->step = [weak, fetch, keyOf, done, limit, maxPages, shortPageEnds]() {
        const auto self = weak.lock();
        if (!self) return;
        fetch(self->offset, limit, [self, keyOf, done, limit, maxPages, shortPageEnds](
                                       QList<T> items, QString err) {
            if (!err.isEmpty()) { done(self->acc, false); return; }
            int added = 0;
            for (const T &item : items) {
                const QString k = keyOf(item);
                if (k.isEmpty() || self->seen.contains(k)) continue;
                self->seen.insert(k);
                self->acc.append(item);
                ++added;
            }
            ++self->pages;
            if ((shortPageEnds && items.size() < limit) || added == 0) {
                done(self->acc, true);
                return;
            }
            if (self->pages >= maxPages) {
                done(self->acc, false);
                return;
            }
            self->offset += int(items.size());
            self->step();
        });
    };
    run->step();
}

// A listing that can lose rows laid over the list on hand: its new rows go in
// front, and nothing on hand is dropped, since a row it lacks may only have
// fallen between two pages.
template <typename T, typename KeyOf>
QList<T> mergeLossy(const QList<T> &onHand, const QList<T> &listed, KeyOf keyOf) {
    QSet<QString> have;
    for (const T &x : onHand) have.insert(keyOf(x));
    QList<T> out;
    for (const T &x : listed)
        if (!have.contains(keyOf(x))) out.append(x);
    out.append(onHand);
    return out;
}

// Lists a favourites list in one page of `bigLimit`, read on to the empty page
// like any other run. Only when Tidal refuses that page does it page at
// `smallLimit` with `paged`. `pagedLoses` says its order has ties, which offset
// paging repeats and skips. `done` gets the list, whether it is whole and
// whether it fell back.
template <typename T, typename Fetch, typename Paged, typename KeyOf, typename Done>
void pageFavorites(Fetch fetch, Paged paged, KeyOf keyOf, Done done, int bigLimit,
                   int smallLimit, int maxPages, const char *what, bool pagedLoses) {
    const auto big = [paged, keyOf, done, smallLimit, maxPages, what, pagedLoses](
                         const QList<T> &all, bool whole) {
        if (whole || !all.isEmpty()) { done(all, whole, false); return; }
        qWarning("favourites: one page of %s failed; paging at %d%s", what, smallLimit,
                 pagedLoses ? ", which can lose rows that share a save date" : "");
        pageEverything<T>(paged, keyOf,
                          [done](const QList<T> &list, bool listWhole) {
                              done(list, listWhole, true);
                          },
                          smallLimit, maxPages, false);
    };
    pageEverything<T>(fetch, keyOf, big, bigLimit, maxPages, false);
}
