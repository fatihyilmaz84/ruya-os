//! The machine-readable error list: what is wrong, where, and how to fix it.

use serde::Serialize;
use std::fmt;

/// One thing wrong with a package.
///
/// `code` is a stable dotted string the shell maps to translated text; `path` is a JSON pointer for
/// a `play.json` problem and the package path for a file problem (empty when it concerns the whole
/// package); `message` is English text a developer can act on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    /// Stable code, see [`codes`].
    pub code: String,
    /// JSON pointer (manifest) or package path (files).
    pub path: String,
    /// What is wrong and what to change.
    pub message: String,
}

impl Problem {
    /// A problem with the given code, location and message.
    pub fn new(code: &str, path: impl Into<String>, message: impl Into<String>) -> Self {
        Problem {
            code: code.to_string(),
            path: path.into(),
            message: message.into(),
        }
    }
}

impl fmt::Display for Problem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.path.is_empty() {
            write!(f, "{}: {}", self.code, self.message)
        } else {
            write!(f, "{} at {}: {}", self.code, self.path, self.message)
        }
    }
}

impl std::error::Error for Problem {}

/// Escape one segment of a JSON pointer (RFC 6901).
pub fn pointer_segment(s: &str) -> String {
    s.replace('~', "~0").replace('/', "~1")
}

/// Append a segment to a JSON pointer.
pub fn pointer_join(base: &str, segment: &str) -> String {
    format!("{base}/{}", pointer_segment(segment))
}

/// The collector the checks write into; stops at [`crate::limits::MAX_PROBLEMS`].
#[derive(Debug, Default)]
pub struct Problems {
    list: Vec<Problem>,
    cut: bool,
}

impl Problems {
    /// An empty collector.
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a problem.
    pub fn add(&mut self, code: &str, path: impl Into<String>, message: impl Into<String>) {
        if self.list.len() >= crate::limits::MAX_PROBLEMS {
            self.cut = true;
            return;
        }
        self.list.push(Problem::new(code, path, message));
    }

    /// True when nothing was recorded.
    pub fn is_empty(&self) -> bool {
        self.list.is_empty()
    }

    /// Number of problems so far.
    pub fn len(&self) -> usize {
        self.list.len()
    }

    /// True once the list is full and a later problem was dropped.
    pub fn is_full(&self) -> bool {
        self.cut
    }

    /// The problems, with a closing `problems.truncated` when some were dropped.
    pub fn finish(mut self) -> Vec<Problem> {
        if self.cut {
            self.list.push(Problem::new(
                codes::PROBLEMS_TRUNCATED,
                "",
                "There are more problems than this list shows; fix these first.",
            ));
        }
        self.list
    }
}

macro_rules! codes {
    ($($name:ident = $value:literal,)*) => {
        /// The stable error codes. A code never changes meaning; a retired code is not reused.
        pub mod codes {
            $(
                #[doc = concat!("`", $value, "`")]
                pub const $name: &str = $value;
            )*
            /// Every code, for tests and for the shell's translation table.
            pub const ALL: &[&str] = &[$($value),*];
        }
    };
}

codes! {
    FORMAT_TOO_NEW = "format.too_new",
    FORMAT_INVALID = "format.invalid",
    MANIFEST_TOO_BIG = "manifest.too_big",
    MANIFEST_TOO_DEEP = "manifest.too_deep",
    MANIFEST_NOT_UTF8 = "manifest.not_utf8",
    MANIFEST_INVALID_JSON = "manifest.invalid_json",
    MANIFEST_TYPE = "manifest.type",
    MANIFEST_MISSING = "manifest.missing",
    VALUE_UNKNOWN = "value.unknown",
    VALUE_RANGE = "value.range",
    LIST_TOO_LONG = "list.too_long",
    LIST_DUPLICATE = "list.duplicate",
    ID_INVALID = "id.invalid",
    ID_FLATPAK_INVALID = "id.flatpak_invalid",
    ID_RESERVED = "id.reserved",
    NAME_RESERVED = "name.reserved",
    TEXT_CONTROL = "text.control",
    TEXT_BIDI = "text.bidi",
    TEXT_ZERO_WIDTH = "text.zero_width",
    TEXT_MARKUP = "text.markup",
    TEXT_LINK = "text.link",
    TEXT_TOO_LONG = "text.too_long",
    TEXT_EMPTY = "text.empty",
    LANG_INVALID = "lang.invalid",
    LANG_TOO_MANY = "lang.too_many",
    LANG_MISSING_EN = "lang.missing_en",
    URL_NOT_HTTPS = "url.not_https",
    URL_INVALID = "url.invalid",
    REQUIREMENTS_ARCH = "requirements.arch",
    PERMISSIONS_UNKNOWN_KEY = "permissions.unknown_key",
    PERMISSIONS_REASON_KEY = "permissions.reason_key",
    COMPONENT_UNKNOWN_KEY = "component.unknown_key",
    COMPONENT_MISSING_FIELD = "component.missing_field",
    COMPONENT_DUPLICATE = "component.duplicate",
    COMPONENT_BUNDLED_MISSING = "component.bundled_missing",
    COMPONENT_PATH = "component.path",
    RUN_UNKNOWN_KEY = "run.unknown_key",
    RUN_COMPONENT_MISSING = "run.component_missing",
    RUN_COMPONENT_UNKNOWN = "run.component_unknown",
    RUN_COMPONENT_TYPE = "run.component_type",
    RUN_COMPONENT_UNEXPECTED = "run.component_unexpected",
    RUN_PLACEHOLDER_COMPONENT = "run.placeholder_component",
    RUN_DISC_PLACEHOLDER_WITHOUT_DISCS = "run.disc_placeholder_without_discs",
    RUN_DISC_NOT_IN_TABLE = "run.disc_not_in_table",
    RUN_DISC_PATH = "run.disc_path",
    RUN_DISC_DUPLICATE = "run.disc_duplicate",
    RUN_COMMAND_MISSING = "run.command_missing",
    RUN_CWD = "run.cwd",
    ENV_BAD_NAME = "env.bad_name",
    ENV_RESERVED = "env.reserved",
    ENV_BAD_VALUE = "env.bad_value",
    PREFIX_DOSDEVICES = "prefix.dosdevices",
    PREFIX_TEMPLATE_MISSING = "prefix.template_missing",
    ART_PATH = "art.path",
    ART_MISSING = "art.missing",
    ART_EXTENSION = "art.extension",
    DATA_PATH = "data.path",
    PATH_EMPTY = "path.empty",
    PATH_TRAVERSAL = "path.traversal",
    PATH_DOT = "path.dot",
    PATH_ABSOLUTE = "path.absolute",
    PATH_BACKSLASH = "path.backslash",
    PATH_COLON = "path.colon",
    PATH_CONTROL = "path.control",
    PATH_EMPTY_COMPONENT = "path.empty_component",
    PATH_COMPONENT_TOO_LONG = "path.component_too_long",
    PATH_TOO_LONG = "path.too_long",
    PATH_NOT_NFC = "path.not_nfc",
    PATH_CASE_COLLISION = "path.case_collision",
    PATH_RESERVED_NAME = "path.reserved_name",
    PATH_TRAILING_DOT_SPACE = "path.trailing_dot_space",
    PATH_INVALID_UTF8 = "path.invalid_utf8",
    ENTRY_SYMLINK = "entry.symlink",
    ENTRY_HARDLINK = "entry.hardlink",
    ENTRY_DEVICE = "entry.device",
    ENTRY_SPECIAL = "entry.special",
    TABLE_NOT_UTF8 = "table.not_utf8",
    TABLE_TOO_BIG = "table.too_big",
    TABLE_TOO_MANY = "table.too_many",
    TABLE_LINE_INVALID = "table.line_invalid",
    TABLE_BLANK_LINE = "table.blank_line",
    TABLE_NOT_SORTED = "table.not_sorted",
    TABLE_DUPLICATE = "table.duplicate",
    TABLE_RESERVED_PATH = "table.reserved_path",
    TABLE_PARENT_NOT_DIR = "table.parent_not_dir",
    LINK_ABSOLUTE = "link.absolute",
    LINK_TARGET_INVALID = "link.target_invalid",
    LINK_AT_ROOT = "link.at_root",
    LINK_ESCAPES_TREE = "link.escapes_tree",
    LINK_LEAVES_TOP_DIR = "link.leaves_top_dir",
    LINK_CHAIN_TOO_LONG = "link.chain_too_long",
    LINK_LOOP = "link.loop",
    LINK_DANGLING = "link.dangling",
    LINK_AS_PARENT = "link.as_parent",
    PACKAGE_NO_MANIFEST = "package.no_manifest",
    PACKAGE_NO_TABLE = "package.no_table",
    PACKAGE_ROOT_KIND = "package.root_kind",
    PACKAGE_EXTRA_FILE = "package.extra_file",
    PACKAGE_EXTRA_DIR = "package.extra_dir",
    PACKAGE_MISSING_FILE = "package.missing_file",
    PACKAGE_MISSING_DIR = "package.missing_dir",
    PACKAGE_KIND_MISMATCH = "package.kind_mismatch",
    PACKAGE_SIZE_MISMATCH = "package.size_mismatch",
    PACKAGE_HASH_MISMATCH = "package.hash_mismatch",
    PACKAGE_READ_FAILED = "package.read_failed",
    PROBLEMS_TRUNCATED = "problems.truncated",
    ZIP_NOT_A_ZIP = "zip.not_a_zip",
    ZIP_TRAILING_DATA = "zip.trailing_data",
    ZIP_LEADING_DATA = "zip.leading_data",
    ZIP_MALFORMED = "zip.malformed",
    ZIP_ENCRYPTED = "zip.encrypted",
    ZIP_METHOD = "zip.method",
    ZIP_MULTI_DISK = "zip.multi_disk",
    ZIP_DUPLICATE_ENTRY = "zip.duplicate_entry",
    ZIP_RATIO = "zip.ratio",
    ZIP_TOO_MANY_ENTRIES = "zip.too_many_entries",
    ZIP_GAP = "zip.gap",
    ZIP_OVERLAP = "zip.overlap",
    ZIP_LOCAL_MISMATCH = "zip.local_mismatch",
    ZIP_DECLARED_SIZE_LIES = "zip.declared_size_lies",
    ZIP_CRC_MISMATCH = "zip.crc_mismatch",
    FOLDER_UNREADABLE = "folder.unreadable",
    FOLDER_TOO_MANY_ENTRIES = "folder.too_many_entries",
}
