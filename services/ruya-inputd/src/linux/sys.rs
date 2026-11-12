//! The raw Linux calls: uinput (with phys and force feedback, which the evdev crate's builder
//! lacks), `EVIOCSFF`/`EVIOCRMFF` on a physical pad, the ACL extended attribute and the udev
//! netlink monitor. The ioctl numbers follow linux/uinput.h and linux/input.h; the struct sizes
//! are checked at compile time.

use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::mem::size_of;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;

use crate::pad::{
    code, OutEvent, Rumble, VIRTUAL_AXES, VIRTUAL_BUS_USB, VIRTUAL_KEYS, VIRTUAL_NAME,
    VIRTUAL_PRODUCT, VIRTUAL_VENDOR, VIRTUAL_VERSION,
};

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct InputId {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
}

#[repr(C)]
struct UinputSetup {
    id: InputId,
    name: [u8; 80],
    ff_effects_max: u32,
}

#[repr(C)]
struct UinputAbsSetup {
    code: u16,
    _pad: u16,
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct FfEffect {
    pub kind: u16,
    pub id: i16,
    direction: u16,
    trigger_button: u16,
    trigger_interval: u16,
    replay_length: u16,
    replay_delay: u16,
    /// The union `u` (aligned to 8 by its pointer member); `ff_rumble_effect` is its first 4 bytes.
    u: [u64; 4],
}

impl FfEffect {
    pub fn rumble(&self) -> Option<Rumble> {
        (self.kind == code::FF_RUMBLE).then(|| Rumble {
            strong: (self.u[0] & 0xffff) as u16,
            weak: ((self.u[0] >> 16) & 0xffff) as u16,
            length_ms: self.replay_length,
            delay_ms: self.replay_delay,
        })
    }

    fn from_rumble(id: i16, r: &Rumble) -> FfEffect {
        FfEffect {
            kind: code::FF_RUMBLE,
            id,
            replay_length: r.length_ms,
            replay_delay: r.delay_ms,
            u: [r.strong as u64 | (r.weak as u64) << 16, 0, 0, 0],
            ..FfEffect::default()
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct FfUpload {
    pub request_id: u32,
    pub retval: i32,
    pub effect: FfEffect,
    pub old: FfEffect,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct FfErase {
    pub request_id: u32,
    pub retval: i32,
    pub effect_id: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RawEvent {
    time: libc::timeval,
    pub kind: u16,
    pub code: u16,
    pub value: i32,
}

impl RawEvent {
    fn new(kind: u16, code: u16, value: i32) -> RawEvent {
        RawEvent {
            time: libc::timeval {
                tv_sec: 0,
                tv_usec: 0,
            },
            kind,
            code,
            value,
        }
    }
}

const _: () = assert!(size_of::<UinputSetup>() == 92);
const _: () = assert!(size_of::<UinputAbsSetup>() == 28);
const _: () = assert!(size_of::<FfEffect>() == 48);
const _: () = assert!(size_of::<FfUpload>() == 104);
const _: () = assert!(size_of::<FfErase>() == 12);
const _: () = assert!(size_of::<RawEvent>() == 24);

const NONE: u32 = 0;
const WRITE: u32 = 1;
const READ: u32 = 2;

const fn ioc(dir: u32, ty: u8, nr: u8, size: usize) -> libc::c_ulong {
    ((dir << 30) | ((size as u32) << 16) | ((ty as u32) << 8) | nr as u32) as libc::c_ulong
}

const UI_DEV_CREATE: libc::c_ulong = ioc(NONE, b'U', 1, 0);
const UI_DEV_DESTROY: libc::c_ulong = ioc(NONE, b'U', 2, 0);
const UI_DEV_SETUP: libc::c_ulong = ioc(WRITE, b'U', 3, size_of::<UinputSetup>());
const UI_ABS_SETUP: libc::c_ulong = ioc(WRITE, b'U', 4, size_of::<UinputAbsSetup>());
const UI_SET_EVBIT: libc::c_ulong = ioc(WRITE, b'U', 100, 4);
const UI_SET_KEYBIT: libc::c_ulong = ioc(WRITE, b'U', 101, 4);
const UI_SET_ABSBIT: libc::c_ulong = ioc(WRITE, b'U', 103, 4);
const UI_SET_FFBIT: libc::c_ulong = ioc(WRITE, b'U', 107, 4);
const UI_SET_PHYS: libc::c_ulong = ioc(WRITE, b'U', 108, size_of::<*const libc::c_char>());
const SYSNAME_LEN: usize = 64;
const UI_GET_SYSNAME: libc::c_ulong = ioc(READ, b'U', 44, SYSNAME_LEN);
const UI_BEGIN_FF_UPLOAD: libc::c_ulong = ioc(READ | WRITE, b'U', 200, size_of::<FfUpload>());
const UI_END_FF_UPLOAD: libc::c_ulong = ioc(WRITE, b'U', 201, size_of::<FfUpload>());
const UI_BEGIN_FF_ERASE: libc::c_ulong = ioc(READ | WRITE, b'U', 202, size_of::<FfErase>());
const UI_END_FF_ERASE: libc::c_ulong = ioc(WRITE, b'U', 203, size_of::<FfErase>());
const EVIOCSFF: libc::c_ulong = ioc(WRITE, b'E', 0x80, size_of::<FfEffect>());
const EVIOCRMFF: libc::c_ulong = ioc(WRITE, b'E', 0x81, 4);

/// `EV_UINPUT` requests on a uinput fd: an app uploads or erases an effect.
pub const EV_UINPUT: u16 = 0x0101;
pub const UI_FF_UPLOAD: u16 = 1;
pub const UI_FF_ERASE: u16 = 2;
/// `EV_FF` codes from here on are gain and autocentre, not effect ids.
pub const FF_GAIN: u16 = 0x60;

const _: () = {
    // The values the Dell spike used (scripts/dell-input-spike.py).
    assert!(UI_SET_PHYS == 0x4008556C);
    assert!(UI_DEV_SETUP == 0x405C5503);
    assert!(UI_ABS_SETUP == 0x401C5504);
    assert!(UI_GET_SYSNAME == 0x8040552C);
};

fn check(ret: libc::c_int) -> io::Result<libc::c_int> {
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(ret)
    }
}

unsafe fn ioctl_int(fd: RawFd, req: libc::c_ulong, arg: libc::c_int) -> io::Result<libc::c_int> {
    check(libc::ioctl(fd, req as _, arg))
}

unsafe fn ioctl_ptr<T>(fd: RawFd, req: libc::c_ulong, arg: *mut T) -> io::Result<libc::c_int> {
    check(libc::ioctl(fd, req as _, arg))
}

fn raw_events(events: &[OutEvent]) -> Vec<u8> {
    let mut all: Vec<RawEvent> = events
        .iter()
        .map(|&(k, c, v)| RawEvent::new(k, c, v))
        .collect();
    all.push(RawEvent::new(code::EV_SYN, 0, 0));
    let len = all.len() * size_of::<RawEvent>();
    // SAFETY: RawEvent is repr(C) plain data; the slice covers exactly the vector's elements.
    unsafe { std::slice::from_raw_parts(all.as_ptr() as *const u8, len) }.to_vec()
}

/// One virtual Xbox 360-style pad on `/dev/uinput`.
pub struct UinputPad {
    file: File,
}

impl UinputPad {
    /// Creates the pad with `phys` (the udev rule's `ruya-input/pad<n>`) and, if `rumble`,
    /// `FF_RUMBLE`. Returns it and its input device's sysfs name (`input23`).
    pub fn create(phys: &str, rumble: bool) -> io::Result<(UinputPad, String)> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open("/dev/uinput")?;
        let fd = file.as_raw_fd();
        let phys =
            CString::new(phys).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        let mut setup = UinputSetup {
            id: InputId {
                bustype: VIRTUAL_BUS_USB,
                vendor: VIRTUAL_VENDOR,
                product: VIRTUAL_PRODUCT,
                version: VIRTUAL_VERSION,
            },
            name: [0; 80],
            ff_effects_max: if rumble { 16 } else { 0 },
        };
        setup.name[..VIRTUAL_NAME.len()].copy_from_slice(VIRTUAL_NAME.as_bytes());
        // SAFETY: every ioctl gets the argument type linux/uinput.h declares for it, on our fd.
        unsafe {
            ioctl_int(fd, UI_SET_EVBIT, code::EV_KEY as _)?;
            ioctl_int(fd, UI_SET_EVBIT, code::EV_ABS as _)?;
            for key in VIRTUAL_KEYS {
                ioctl_int(fd, UI_SET_KEYBIT, key as _)?;
            }
            for (abs, min, max, fuzz, flat) in VIRTUAL_AXES {
                ioctl_int(fd, UI_SET_ABSBIT, abs as _)?;
                let mut a = UinputAbsSetup {
                    code: abs,
                    _pad: 0,
                    value: 0,
                    minimum: min,
                    maximum: max,
                    fuzz,
                    flat,
                    resolution: 0,
                };
                ioctl_ptr(fd, UI_ABS_SETUP, &mut a)?;
            }
            if rumble {
                ioctl_int(fd, UI_SET_EVBIT, code::EV_FF as _)?;
                ioctl_int(fd, UI_SET_FFBIT, code::FF_RUMBLE as _)?;
            }
            check(libc::ioctl(fd, UI_SET_PHYS as _, phys.as_ptr()))?;
            ioctl_ptr(fd, UI_DEV_SETUP, &mut setup)?;
            check(libc::ioctl(fd, UI_DEV_CREATE as _))?;
        }
        let mut name = [0u8; SYSNAME_LEN];
        // SAFETY: the buffer is SYSNAME_LEN bytes, the size encoded in the request.
        unsafe { ioctl_ptr(fd, UI_GET_SYSNAME, name.as_mut_ptr())? };
        let end = name.iter().position(|&b| b == 0).unwrap_or(SYSNAME_LEN);
        let sysname = String::from_utf8_lossy(&name[..end]).into_owned();
        Ok((UinputPad { file }, sysname))
    }

    pub fn write(&self, events: &[OutEvent]) -> io::Result<()> {
        (&self.file).write_all(&raw_events(events))
    }

    pub fn destroy(&self) {
        // SAFETY: no argument.
        if let Err(err) = check(unsafe { libc::ioctl(self.file.as_raw_fd(), UI_DEV_DESTROY as _) })
        {
            eprintln!("ruya-inputd: UI_DEV_DESTROY failed: {err}");
        }
    }

    /// Waits up to `timeout_ms` for requests and events from the kernel (an app's rumble).
    pub fn read(&self, timeout_ms: i32) -> Vec<RawEvent> {
        let mut pfd = libc::pollfd {
            fd: self.file.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one pollfd.
        if unsafe { libc::poll(&mut pfd, 1, timeout_ms) } <= 0 {
            return Vec::new();
        }
        let mut buf = [RawEvent::new(0, 0, 0); 16];
        // SAFETY: the buffer holds 16 RawEvents; read writes at most that many bytes.
        let n = unsafe {
            libc::read(
                self.file.as_raw_fd(),
                buf.as_mut_ptr() as *mut libc::c_void,
                size_of::<[RawEvent; 16]>(),
            )
        };
        if n <= 0 {
            return Vec::new();
        }
        buf[..n as usize / size_of::<RawEvent>()].to_vec()
    }

    pub fn begin_upload(&self, request_id: u32) -> io::Result<FfUpload> {
        let mut up = FfUpload {
            request_id,
            ..FfUpload::default()
        };
        // SAFETY: the struct is the ioctl's uinput_ff_upload.
        unsafe { ioctl_ptr(self.file.as_raw_fd(), UI_BEGIN_FF_UPLOAD, &mut up)? };
        Ok(up)
    }

    pub fn end_upload(&self, mut up: FfUpload) {
        // SAFETY: as above.
        let _ = unsafe { ioctl_ptr(self.file.as_raw_fd(), UI_END_FF_UPLOAD, &mut up) };
    }

    pub fn begin_erase(&self, request_id: u32) -> io::Result<FfErase> {
        let mut er = FfErase {
            request_id,
            ..FfErase::default()
        };
        // SAFETY: the struct is the ioctl's uinput_ff_erase.
        unsafe { ioctl_ptr(self.file.as_raw_fd(), UI_BEGIN_FF_ERASE, &mut er)? };
        Ok(er)
    }

    pub fn end_erase(&self, mut er: FfErase) {
        // SAFETY: as above.
        let _ = unsafe { ioctl_ptr(self.file.as_raw_fd(), UI_END_FF_ERASE, &mut er) };
    }
}

/// Uploads a rumble effect to a physical pad (`id` -1: new); returns the pad's effect id.
pub fn ff_upload(file: &File, id: i16, rumble: &Rumble) -> Result<i16, i32> {
    let mut effect = FfEffect::from_rumble(id, rumble);
    // SAFETY: the struct is the ioctl's ff_effect.
    match unsafe { ioctl_ptr(file.as_raw_fd(), EVIOCSFF, &mut effect) } {
        Ok(_) => Ok(effect.id),
        Err(err) => Err(err.raw_os_error().unwrap_or(libc::EIO)),
    }
}

pub fn ff_play(file: &File, id: i16, value: i32) -> io::Result<()> {
    let bytes = raw_events(&[(code::EV_FF, id as u16, value)]);
    // The SYN_REPORT raw_events appends is harmless on an evdev node.
    (&*file).write_all(&bytes)
}

pub fn ff_erase(file: &File, id: i16) {
    // SAFETY: EVIOCRMFF takes the effect id by value.
    let _ = unsafe { ioctl_int(file.as_raw_fd(), EVIOCRMFF, id as libc::c_int) };
}

fn c_path(path: &str) -> io::Result<CString> {
    CString::new(path).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))
}

/// The `system.posix_acl_access` attribute of a node; `None` when it has none.
pub fn read_xattr(path: &str, name: &str) -> Option<Vec<u8>> {
    let (path, name) = (c_path(path).ok()?, c_path(name).ok()?);
    let mut buf = vec![0u8; 512];
    // SAFETY: the buffer's length is passed.
    let n = unsafe {
        libc::getxattr(
            path.as_ptr(),
            name.as_ptr(),
            buf.as_mut_ptr() as *mut libc::c_void,
            buf.len(),
        )
    };
    if n < 0 {
        return None;
    }
    buf.truncate(n as usize);
    Some(buf)
}

pub fn write_xattr(path: &str, name: &str, value: &[u8]) -> io::Result<()> {
    let (path, name) = (c_path(path)?, c_path(name)?);
    // SAFETY: value and its length.
    check(unsafe {
        libc::setxattr(
            path.as_ptr(),
            name.as_ptr(),
            value.as_ptr() as *const libc::c_void,
            value.len(),
            0,
        )
    })
    .map(|_| ())
}

/// The udev monitor: netlink group 2, the events udevd broadcasts once it has processed them
/// (rules, RUN programs and logind's uaccess builtin included).
pub struct Monitor {
    fd: RawFd,
}

const UDEV_GROUP: u32 = 2;

impl Monitor {
    pub fn open() -> io::Result<Monitor> {
        // SAFETY: plain socket calls with a zeroed, then filled sockaddr_nl.
        unsafe {
            let fd = check(libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_DGRAM | libc::SOCK_CLOEXEC,
                libc::NETLINK_KOBJECT_UEVENT,
            ))?;
            let mut addr: libc::sockaddr_nl = std::mem::zeroed();
            addr.nl_family = libc::AF_NETLINK as libc::sa_family_t;
            addr.nl_groups = UDEV_GROUP;
            let bind = libc::bind(
                fd,
                &addr as *const libc::sockaddr_nl as *const libc::sockaddr,
                size_of::<libc::sockaddr_nl>() as libc::socklen_t,
            );
            if bind < 0 {
                let err = io::Error::last_os_error();
                libc::close(fd);
                return Err(err);
            }
            let size: libc::c_int = 1 << 20;
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                &size as *const libc::c_int as *const libc::c_void,
                size_of::<libc::c_int>() as libc::socklen_t,
            );
            Ok(Monitor { fd })
        }
    }

    /// The next message; blocks.
    pub fn recv(&self) -> io::Result<Vec<u8>> {
        let mut buf = vec![0u8; 16384];
        // SAFETY: the buffer's length is passed.
        let n = unsafe { libc::recv(self.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        buf.truncate(n as usize);
        Ok(buf)
    }
}

impl Drop for Monitor {
    fn drop(&mut self) {
        // SAFETY: our own fd.
        unsafe { libc::close(self.fd) };
    }
}
