import QtQuick

// The number of a connected pad whose shown name is the same as another connected pad's (RUY-743):
// the first to connect keeps "X", the next is "X 2", then "X 3". The shell's own state, nothing stored.
//
// `entries` is [{ id, base }]: every connected pad with the name it would show without a number, in the
// order the list gives. On every change the registry settles the numbers:
//  - a pad keeps its number while it stays connected and its base name does not change (no live
//    renumbering: when pad 1 leaves, pad 2 stays "2");
//  - a new pad takes the lowest number free among the pads of its name (1 shows no number);
//  - a pad that left and comes back within `holdMs` (the seat hold, 06 §11.3) gets its old number back
//    when that is still free.
// Two pads whose shown names differ are in different groups and never get a number.
QtObject {
    id: reg

    property var entries: []
    property int holdMs: 60000

    // idLower -> { n, key } for the pads connected now.
    property var numbers: ({})
    // idLower -> { n, key, at } for the pads that left, until `holdMs` is over.
    property var held: ({})

    function lower(id) {
        return String(id ?? "").toLowerCase()
    }

    function settle() {
        const now = Date.now()
        const list = reg.entries ?? []
        const present = ({})
        for (const e of list)
            present[reg.lower(e.id)] = true
        const nextHeld = ({})
        for (const id in reg.held) {
            if (now - reg.held[id].at < reg.holdMs && !(id in present))
                nextHeld[id] = reg.held[id]
        }
        for (const id in reg.numbers) {
            if (!(id in present))
                nextHeld[id] = { n: reg.numbers[id].n, key: reg.numbers[id].key, at: now }
        }
        const next = ({})
        const used = ({})
        const take = (key, n) => {
            if (!(key in used))
                used[key] = ({})
            used[key][n] = true
        }
        const free = (key, n) => !(key in used) || !used[key][n]
        const todo = []
        for (const e of list) {
            const id = reg.lower(e.id)
            const key = String(e.base ?? "").toLowerCase()
            const old = reg.numbers[id]
            if (old && old.key === key) {
                next[id] = old
                take(key, old.n)
            } else {
                todo.push({ id: id, key: key })
            }
        }
        for (const t of todo) {
            let n = 1
            const h = nextHeld[t.id]
            if (h && h.key === t.key && free(t.key, h.n))
                n = h.n
            else
                while (!free(t.key, n))
                    n++
            take(t.key, n)
            next[t.id] = { n: n, key: t.key }
            delete nextHeld[t.id]
        }
        reg.numbers = next
        reg.held = nextHeld
    }

    onEntriesChanged: settle()
    Component.onCompleted: settle()

    // The number of the pad: 1 when it has no twin or is unknown. A pad that left still has its number
    // for as long as it is held (the "disconnected" toast comes after the pad is gone).
    function numberOf(id) {
        const k = reg.lower(id)
        if (k in reg.numbers)
            return reg.numbers[k].n
        const h = reg.held[k]
        return h && Date.now() - h.at < reg.holdMs ? h.n : 1
    }

    function knows(id) {
        const k = reg.lower(id)
        return k in reg.numbers || (k in reg.held && Date.now() - reg.held[k].at < reg.holdMs)
    }

    // " 2" for the second pad of a name, "" for the first. The number follows the name ("%1 %2").
    function tail(id) {
        const n = reg.numberOf(id)
        if (n <= 1)
            return ""
        //: A controller name followed by its number when two connected controllers are named alike, e.g.
        //: "PlayStation controller 2". The name (%1) must stay first; it is replaced by nothing here, so
        //: only the " %2" part shows.
        return qsTr("%1 %2").replace("%1", () => "").replace("%2", () => String(n))
    }
}
