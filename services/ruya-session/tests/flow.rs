//! The `--session` flow without a bus: the same core and fake spawner `main.rs` wires up, with
//! the event channel drained by hand where the adapter's `forward` would do it.

use std::time::Instant;

use ruya_session::directory::ProfileSnapshot;
use ruya_session::session::{Notice, Session, Status};
use ruya_session::spawner::FakeSpawner;

const APP: &str = "org.ruyaos.Racer";

#[test]
fn launch_started_stop_exited() {
    let (tx, rx) = async_channel::unbounded();
    let spawner = FakeSpawner::new().with_app(APP).with_events(tx);
    let dir = ProfileSnapshot::new(["p1".to_owned()]);
    let mut session = Session::new(spawner, dir, vec![]);
    let mut notices = Vec::new();
    let mut drain = |session: &mut Session<_, _>| {
        while let Ok(event) = rx.try_recv() {
            notices.extend(session.on_event(event));
        }
    };

    let (status, instance) = session.launch(APP, "p1", 1_000);
    assert_eq!(status, Status::Ok);
    drain(&mut session);
    assert_eq!(session.list().len(), 1);

    assert_eq!(session.stop(&instance, Instant::now()), Status::Ok);
    drain(&mut session);
    assert!(session.list().is_empty());

    assert_eq!(
        notices,
        [
            Notice::Started {
                instance: instance.clone(),
                app_id: APP.to_owned()
            },
            Notice::Exited {
                instance,
                app_id: APP.to_owned(),
                exit_code: 0,
                reason: ruya_session::session::ExitReason::Quit
            },
        ]
    );
}
