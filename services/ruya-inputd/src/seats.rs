//! The players' seats (ADR-017, 06 §11.3; RUY-121): while a profile is signed in the session has
//! four seats, each one profile on one pad. Pure: the router (`routing.rs`) checks the arguments,
//! keeps the virtual pads in step and announces the changes.
//!
//! Rules:
//! - Seat 1 is player 1: the signed-in profile on the pad that signed it in, or on no pad ("")
//!   after a keyboard sign-in. Seats 2-4 start empty. Seats exist only while someone is signed in.
//! - A pad holds at most one profile and a profile at most one pad.
//! - `join(d, p)`: (a) `p` is player 1: `d` becomes seat 1's pad; (b) `p` sits in seat n >= 2: it
//!   moves to `d` and keeps n; (c) `d` sits as another profile: that profile leaves first (seat 1
//!   keeps its profile without a pad); (d) else the lowest free seat of 2-4 (`join_in_order`: the
//!   first free one of an order the router gives, RUY-681), or `Full` with nothing changed; (e) the
//!   same `d` and `p` again change nothing.
//! - A seated pad that is gone holds its seat (RUY-627): the seat keeps its pad's id, `held` until a
//!   deadline. The same id back resumes it (`resume`), a like pad takes it over (`take_over`), a
//!   join that moves the profile ends it, and at the deadline (`expire`) the seat is freed (2-4) or
//!   seat 1 keeps its profile without a pad (`pad_gone`).

use std::time::Instant;

/// How many seats a signed-in session has (ADR-017, a lead decision of 2026-11-14).
pub const SEATS: u32 = 4;

/// One seated player, as `ListPlayers` and `PlayersChanged` carry it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Player {
    /// 1..=SEATS.
    pub slot: u32,
    pub profile: String,
    /// The pad's stable id, "" when the seat has no pad (seat 1 only).
    pub device_id: String,
    /// The pad is gone and the seat waits for it until then (RUY-627); `None` when it is not held.
    pub held_until: Option<Instant>,
}

impl Player {
    /// The whole seconds the hold has left at `now`, rounded up (0 when the seat is not held).
    pub fn held_secs(&self, now: Instant) -> u32 {
        self.held_until.map_or(0, |until| {
            let left = until.saturating_duration_since(now).as_millis();
            u32::try_from(left.div_ceil(1000)).unwrap_or(u32::MAX)
        })
    }
}

/// What `join` did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Joined {
    /// The profile sits on the pad in this seat now (also when it already did: `changed` false).
    Seated { slot: u32, changed: bool },
    /// No free seat: nothing changed.
    Full,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Seat {
    profile: String,
    device: String,
    held_until: Option<Instant>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Seats {
    /// Index 0 is seat 1. Empty while nobody is signed in; seat 1 is always taken otherwise.
    seats: Vec<Option<Seat>>,
}

impl Seats {
    /// A profile change: every seat is emptied, then `profile` (if any) is seat 1 on `device`
    /// ("" for none).
    pub fn sign_in(&mut self, profile: &str, device: &str) {
        self.seats.clear();
        if profile.is_empty() {
            return;
        }
        self.seats = vec![None; SEATS as usize];
        self.seats[0] = Some(Seat {
            profile: profile.to_owned(),
            device: device.to_owned(),
            held_until: None,
        });
    }

    /// Whether a profile is signed in (seats exist).
    pub fn active(&self) -> bool {
        !self.seats.is_empty()
    }

    /// The seated players, by slot.
    pub fn players(&self) -> Vec<Player> {
        self.seats
            .iter()
            .enumerate()
            .filter_map(|(i, s)| {
                s.as_ref().map(|s| Player {
                    slot: i as u32 + 1,
                    profile: s.profile.clone(),
                    device_id: s.device.clone(),
                    held_until: s.held_until,
                })
            })
            .collect()
    }

    /// The seat and profile of a pad, if it is seated.
    pub fn seat_of(&self, device: &str) -> Option<(u32, &str)> {
        if device.is_empty() {
            return None;
        }
        self.seats.iter().enumerate().find_map(|(i, s)| {
            s.as_ref()
                .filter(|s| s.device == device)
                .map(|s| (i as u32 + 1, s.profile.as_str()))
        })
    }

    /// Seat 1's pad (player 1's active controller), if it has one.
    pub fn player1_device(&self) -> Option<&str> {
        self.seats
            .first()
            .and_then(|s| s.as_ref())
            .map(|s| s.device.as_str())
            .filter(|d| !d.is_empty())
    }

    fn slot_of_profile(&self, profile: &str) -> Option<usize> {
        self.seats
            .iter()
            .position(|s| s.as_ref().is_some_and(|s| s.profile == profile))
    }

    /// `JoinPlayer` once its arguments are checked: `device` is a connected pad, `profile` a
    /// profile account, and someone is signed in. Rules (a) to (e) of the module.
    pub fn join(&mut self, device: &str, profile: &str) -> Joined {
        self.join_in_order(device, profile, &[])
    }

    /// `join` whose rule (d) takes the first free seat of `order` (seats 2..=SEATS; others are
    /// ignored), then the lowest free one.
    pub fn join_in_order(&mut self, device: &str, profile: &str, order: &[u32]) -> Joined {
        if !self.active() || device.is_empty() {
            return Joined::Full;
        }
        if let Some((slot, p)) = self.seat_of(device) {
            if p == profile {
                return Joined::Seated {
                    slot,
                    changed: false,
                };
            }
        }
        let mut next = self.clone();
        // (c) The pad sits as another profile: that one leaves first (seat 1 keeps its profile).
        if let Some((slot, _)) = next.seat_of(device) {
            let i = slot as usize - 1;
            if i == 0 {
                if let Some(s) = next.seats[0].as_mut() {
                    s.device.clear();
                }
            } else {
                next.seats[i] = None;
            }
        }
        let slot = match next.slot_of_profile(profile) {
            // (a) player 1, and (b) a player of seat n >= 2: the profile moves to the pad and keeps
            // its seat; the pad it had is unseated, and a hold of the seat ends (RUY-627).
            Some(i) => {
                if let Some(s) = next.seats[i].as_mut() {
                    s.device = device.to_owned();
                    s.held_until = None;
                }
                i
            }
            // (d) the first free seat of the order, else the lowest free seat of 2..=SEATS.
            None => {
                let free = |i: usize| i >= 1 && next.seats.get(i).is_some_and(Option::is_none);
                let Some(i) = order
                    .iter()
                    .map(|&n| (n as usize).wrapping_sub(1))
                    .find(|&i| free(i))
                    .or_else(|| (1..next.seats.len()).find(|&i| free(i)))
                else {
                    return Joined::Full;
                };
                next.seats[i] = Some(Seat {
                    profile: profile.to_owned(),
                    device: device.to_owned(),
                    held_until: None,
                });
                i
            }
        };
        *self = next;
        Joined::Seated {
            slot: slot as u32 + 1,
            changed: true,
        }
    }

    /// `LeavePlayer(slot)` for a slot of 2..=SEATS: the pad it had, if the seat was taken.
    pub fn leave(&mut self, slot: u32) -> Option<String> {
        if !(2..=SEATS).contains(&slot) {
            return None;
        }
        self.seats
            .get_mut(slot as usize - 1)
            .and_then(Option::take)
            .map(|s| s.device)
    }

    /// The pad `device` is gone for good (its hold ran out): its seat is freed (2..=SEATS) or seat
    /// 1 keeps its profile without a pad. The slot it had, if any.
    pub fn pad_gone(&mut self, device: &str) -> Option<u32> {
        let (slot, _) = self.seat_of(device)?;
        let i = slot as usize - 1;
        if i == 0 {
            if let Some(s) = self.seats[0].as_mut() {
                s.device.clear();
                s.held_until = None;
            }
        } else {
            self.seats[i] = None;
        }
        Some(slot)
    }

    fn seat_mut(&mut self, device: &str) -> Option<&mut Seat> {
        if device.is_empty() {
            return None;
        }
        self.seats.iter_mut().flatten().find(|s| s.device == device)
    }

    /// The seated pad `device` disconnected: its seat is held until `until` (seat 1 too). The slot,
    /// if the pad was seated and not held already.
    pub fn hold(&mut self, device: &str, until: Instant) -> Option<u32> {
        let (slot, _) = self.seat_of(device)?;
        let seat = self.seat_mut(device)?;
        if seat.held_until.is_some() {
            return None;
        }
        seat.held_until = Some(until);
        Some(slot)
    }

    /// Whether the seat of `device` is held (its pad is gone).
    pub fn is_held(&self, device: &str) -> bool {
        !device.is_empty()
            && self
                .seats
                .iter()
                .flatten()
                .any(|s| s.device == device && s.held_until.is_some())
    }

    /// The held seats: (slot, the gone pad's id), by slot.
    pub fn held(&self) -> Vec<(u32, String)> {
        self.seats
            .iter()
            .enumerate()
            .filter_map(|(i, s)| {
                s.as_ref()
                    .filter(|s| s.held_until.is_some())
                    .map(|s| (i as u32 + 1, s.device.clone()))
            })
            .collect()
    }

    /// The pad `device` is back within its hold: the seat is its again. The slot, if it was held.
    pub fn resume(&mut self, device: &str) -> Option<u32> {
        let (slot, _) = self.seat_of(device)?;
        let seat = self.seat_mut(device)?;
        seat.held_until.take()?;
        Some(slot)
    }

    /// A like pad `new` takes the held seat of the gone pad `old` (06 §4.1): the seat's pad is `new`
    /// now and the hold ends. The slot, if `old`'s seat was held and `new` sits nowhere.
    pub fn take_over(&mut self, old: &str, new: &str) -> Option<u32> {
        if new.is_empty() || self.seat_of(new).is_some() || !self.is_held(old) {
            return None;
        }
        let (slot, _) = self.seat_of(old)?;
        let seat = self.seat_mut(old)?;
        seat.device = new.to_owned();
        seat.held_until = None;
        Some(slot)
    }

    /// The holds that ran out at `now`: each such pad is gone for good (`pad_gone`). Their (slot,
    /// pad id), by slot.
    pub fn expire(&mut self, now: Instant) -> Vec<(u32, String)> {
        let due: Vec<(u32, String)> = self
            .seats
            .iter()
            .enumerate()
            .filter_map(|(i, s)| {
                s.as_ref()
                    .filter(|s| s.held_until.is_some_and(|t| t <= now))
                    .map(|s| (i as u32 + 1, s.device.clone()))
            })
            .collect();
        for (_, device) in &due {
            self.pad_gone(device);
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(s: &Seats) -> Vec<(u32, String, String)> {
        s.players()
            .into_iter()
            .map(|p| (p.slot, p.profile, p.device_id))
            .collect()
    }

    fn row(slot: u32, profile: &str, device: &str) -> (u32, String, String) {
        (slot, profile.to_owned(), device.to_owned())
    }

    fn seated(slot: u32) -> Joined {
        Joined::Seated {
            slot,
            changed: true,
        }
    }

    #[test]
    fn no_seats_while_nobody_is_signed_in() {
        let mut s = Seats::default();
        assert!(!s.active());
        assert_eq!(s.join("a", "p1"), Joined::Full);
        assert!(s.players().is_empty());
        s.sign_in("p1", "a");
        s.sign_in("", "");
        assert!(!s.active());
    }

    #[test]
    fn a_sign_in_seats_player_1_on_its_pad_or_on_none() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        assert_eq!(line(&s), vec![row(1, "p1", "a")]);
        assert_eq!(s.player1_device(), Some("a"));
        s.sign_in("p2", "");
        assert_eq!(line(&s), vec![row(1, "p2", "")]);
        assert_eq!(s.player1_device(), None);
    }

    #[test]
    fn join_a_player_1_moves_to_the_new_pad() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        assert_eq!(s.join("b", "p1"), seated(1));
        assert_eq!(line(&s), vec![row(1, "p1", "b")]);
        assert_eq!(s.seat_of("a"), None, "the old pad is unseated");
    }

    #[test]
    fn join_b_a_player_moves_to_the_new_pad_and_keeps_the_seat() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        s.join("c", "p3");
        assert_eq!(s.join("d", "p2"), seated(2));
        assert_eq!(
            line(&s),
            vec![row(1, "p1", "a"), row(2, "p2", "d"), row(3, "p3", "c")]
        );
        assert_eq!(s.seat_of("b"), None, "the old pad is unseated");
    }

    #[test]
    fn join_c_a_pad_seated_as_another_profile_leaves_that_seat_first() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        // b was p2's: p2 leaves seat 2, p3 takes the lowest free seat, 2.
        assert_eq!(s.join("b", "p3"), seated(2));
        assert_eq!(line(&s), vec![row(1, "p1", "a"), row(2, "p3", "b")]);
        // Player 1's pad joins as p4: player 1 stays, without a pad.
        assert_eq!(s.join("a", "p4"), seated(3));
        assert_eq!(
            line(&s),
            vec![row(1, "p1", ""), row(2, "p3", "b"), row(3, "p4", "a")]
        );
        // And p4's pad joins as player 1 again: p4 leaves seat 3.
        assert_eq!(s.join("a", "p1"), seated(1));
        assert_eq!(line(&s), vec![row(1, "p1", "a"), row(2, "p3", "b")]);
    }

    #[test]
    fn join_d_the_lowest_free_seat_from_2() {
        let mut s = Seats::default();
        s.sign_in("p1", "");
        assert_eq!(s.join("b", "p2"), seated(2));
        assert_eq!(s.join("c", "p3"), seated(3));
        s.leave(2);
        assert_eq!(s.join("d", "p4"), seated(2));
    }

    #[test]
    fn join_e_the_same_pad_and_profile_again_change_nothing() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        s.join("c", "p3");
        s.leave(2);
        let before = s.clone();
        // Seat 2 is free, and p3 on c again keeps seat 3.
        assert_eq!(
            s.join("c", "p3"),
            Joined::Seated {
                slot: 3,
                changed: false
            }
        );
        assert_eq!(
            s.join("a", "p1"),
            Joined::Seated {
                slot: 1,
                changed: false
            }
        );
        assert_eq!(s, before);
    }

    #[test]
    fn the_fourth_join_is_full_and_changes_nothing() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        assert_eq!(s.join("b", "p2"), seated(2));
        assert_eq!(s.join("c", "p3"), seated(3));
        assert_eq!(s.join("d", "p4"), seated(4));
        let before = s.clone();
        assert_eq!(s.join("e", "p5"), Joined::Full);
        assert_eq!(s, before);
        // A pad seated as another profile frees that seat first, so it is not full.
        assert_eq!(s.join("d", "p5"), seated(4));
    }

    #[test]
    fn join_in_order_takes_the_first_free_seat_of_the_order_then_the_lowest() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        // Seat 2 is taken, 1 and 5 are no seats to join: the order's 4 it is.
        assert_eq!(s.join_in_order("c", "p3", &[0, 1, 2, 5, 4, 3]), seated(4));
        // An order with no free seat in it falls back to the lowest free seat.
        assert_eq!(s.join_in_order("d", "p4", &[2, 4]), seated(3));
        assert_eq!(s.join_in_order("e", "p5", &[2]), Joined::Full);
        // Rules (a) and (b) come first: a seated profile keeps its seat whatever the order.
        assert_eq!(s.join_in_order("f", "p2", &[3]), seated(2));
    }

    #[test]
    fn leave_frees_seats_2_to_4_only() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        assert_eq!(s.leave(1), None);
        assert_eq!(s.leave(5), None);
        assert_eq!(s.leave(3), None);
        assert_eq!(s.leave(2), Some("b".to_owned()));
        assert_eq!(line(&s), vec![row(1, "p1", "a")]);
    }

    #[test]
    fn a_pad_that_is_gone_frees_its_seat_or_leaves_seat_1_without_a_pad() {
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        assert_eq!(s.pad_gone("b"), Some(2));
        assert_eq!(s.pad_gone("a"), Some(1));
        assert_eq!(s.pad_gone("z"), None);
        assert_eq!(line(&s), vec![row(1, "p1", "")]);
    }

    // ---- the hold (RUY-627) ---------------------------------------------------------------

    use std::time::Duration;

    fn held(s: &Seats) -> Vec<(u32, bool)> {
        s.players()
            .into_iter()
            .map(|p| (p.slot, p.held_until.is_some()))
            .collect()
    }

    #[test]
    fn a_gone_pad_holds_its_seat_with_its_id_seat_1_too() {
        let t = Instant::now();
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        assert_eq!(s.hold("b", t + Duration::from_secs(60)), Some(2));
        assert_eq!(s.hold("a", t + Duration::from_secs(60)), Some(1));
        assert_eq!(s.hold("b", t), None, "held already");
        assert_eq!(s.hold("z", t), None, "not seated");
        assert_eq!(line(&s), vec![row(1, "p1", "a"), row(2, "p2", "b")]);
        assert_eq!(held(&s), vec![(1, true), (2, true)]);
        assert_eq!(s.held(), vec![(1, "a".into()), (2, "b".into())]);
        assert_eq!(s.players()[1].held_secs(t), 60);
        assert_eq!(
            s.players()[1].held_secs(t + Duration::from_millis(59_001)),
            1,
            "rounded up"
        );
        assert_eq!(s.players()[1].held_secs(t + Duration::from_secs(61)), 0);
        assert_eq!(s.resume("b"), Some(2));
        assert_eq!(s.resume("b"), None, "not held now");
        assert_eq!(held(&s), vec![(1, true), (2, false)]);
        assert_eq!(s.player1_device(), Some("a"));
    }

    #[test]
    fn a_hold_that_runs_out_frees_the_seat_and_seat_1_keeps_its_profile() {
        let t = Instant::now();
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        s.join("c", "p3");
        s.hold("a", t + Duration::from_secs(60));
        s.hold("b", t + Duration::from_secs(60));
        s.hold("c", t + Duration::from_secs(90));
        assert!(s.expire(t + Duration::from_secs(59)).is_empty());
        assert_eq!(
            s.expire(t + Duration::from_secs(60)),
            vec![(1, "a".into()), (2, "b".into())]
        );
        assert_eq!(line(&s), vec![row(1, "p1", ""), row(3, "p3", "c")]);
        assert_eq!(held(&s), vec![(1, false), (3, true)]);
    }

    #[test]
    fn a_like_pad_takes_over_a_held_seat_only() {
        let t = Instant::now();
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        assert_eq!(s.take_over("b", "b2"), None, "b is not held");
        s.hold("b", t);
        assert_eq!(s.take_over("b", "a"), None, "a sits already");
        assert_eq!(s.take_over("b", "b2"), Some(2));
        assert_eq!(line(&s), vec![row(1, "p1", "a"), row(2, "p2", "b2")]);
        assert_eq!(held(&s), vec![(1, false), (2, false)]);
    }

    #[test]
    fn a_join_that_moves_a_held_seat_ends_the_hold() {
        let t = Instant::now();
        let mut s = Seats::default();
        s.sign_in("p1", "a");
        s.join("b", "p2");
        s.hold("a", t);
        s.hold("b", t);
        assert_eq!(s.join("c", "p2"), seated(2));
        assert_eq!(s.join("d", "p1"), seated(1));
        assert_eq!(line(&s), vec![row(1, "p1", "d"), row(2, "p2", "c")]);
        assert!(s.held().is_empty());
        // A sign-in holds nothing.
        s.hold("c", t);
        s.sign_in("p1", "c");
        assert!(s.held().is_empty());
    }
}
