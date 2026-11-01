// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <QList>
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
