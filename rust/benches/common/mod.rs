//! Common utilities for benchmark test data generation.
//!
//! Generates realistic symbol patterns for TypeScript, Go, and Lua.

use code_shape_core::index::{Position, Range, Symbol};

// LSP SymbolKind constants
pub const FUNCTION: u32 = 12;
pub const METHOD: u32 = 6;
pub const CLASS: u32 = 5;
pub const INTERFACE: u32 = 11;
#[allow(dead_code)]
pub const VARIABLE: u32 = 13;
#[allow(dead_code)]
pub const CONSTANT: u32 = 14;
pub const STRUCT: u32 = 23;
#[allow(dead_code)]
pub const MODULE: u32 = 2;

/// Create a symbol with the given parameters.
pub fn make_symbol(id: &str, name: &str, uri: &str, kind: u32, container: Option<&str>) -> Symbol {
    Symbol {
        symbol_id: id.to_string(),
        name: name.to_string(),
        kind,
        container_name: container.map(|s| s.to_string()),
        uri: uri.to_string(),
        range: Range {
            start: Position {
                line: 0,
                character: 0,
            },
            end: Position {
                line: 0,
                character: 10,
            },
        },
        detail: None,
        metrics: None,
    }
}

// TypeScript naming patterns
const TS_FUNCTION_PREFIXES: &[&str] = &[
    "fetch",
    "parse",
    "handle",
    "validate",
    "transform",
    "process",
    "create",
    "update",
    "delete",
    "get",
    "set",
    "init",
    "load",
    "save",
    "render",
    "compute",
    "calculate",
    "format",
    "sanitize",
    "serialize",
    "deserialize",
    "encode",
    "decode",
    "convert",
];

const TS_FUNCTION_SUFFIXES: &[&str] = &[
    "Data",
    "Response",
    "Request",
    "Error",
    "Input",
    "Output",
    "Result",
    "Config",
    "State",
    "Props",
    "Context",
    "Payload",
    "Message",
    "Event",
    "Handler",
    "Callback",
    "User",
    "Item",
    "List",
    "Tree",
    "Node",
    "Element",
    "Component",
    "Module",
];

const TS_CLASS_NAMES: &[&str] = &[
    "UserService",
    "ApiClient",
    "DataProcessor",
    "ConfigManager",
    "StateManager",
    "EventHandler",
    "RequestHandler",
    "ResponseParser",
    "CacheManager",
    "Logger",
    "Database",
    "Connection",
    "Session",
    "AuthProvider",
    "Validator",
    "Transformer",
    "Renderer",
    "Controller",
    "Service",
    "Repository",
];

const TS_INTERFACE_PREFIXES: &[&str] = &["I", ""];
const TS_INTERFACE_NAMES: &[&str] = &[
    "User", "Config", "Options", "Settings", "Response", "Request", "State", "Props", "Context",
    "Handler", "Provider", "Store", "Api", "Client",
];

/// Generate TypeScript-style symbols.
///
/// Patterns:
/// - Functions: camelCase verbs (fetchData, parseResponse)
/// - Classes: PascalCase nouns (UserService, ApiClient)
/// - Interfaces: I-prefix PascalCase (IUserService, IConfig)
pub fn typescript_symbols(uri: &str, count: usize) -> Vec<Symbol> {
    let mut symbols = Vec::with_capacity(count);
    let mut id_counter = 0;

    // Generate functions (60% of symbols)
    let func_count = count * 6 / 10;
    for i in 0..func_count {
        let prefix = TS_FUNCTION_PREFIXES[i % TS_FUNCTION_PREFIXES.len()];
        let suffix =
            TS_FUNCTION_SUFFIXES[(i / TS_FUNCTION_PREFIXES.len()) % TS_FUNCTION_SUFFIXES.len()];
        let name = format!("{}{}", prefix, suffix);

        let container = if i % 3 == 0 {
            Some(TS_CLASS_NAMES[i % TS_CLASS_NAMES.len()])
        } else {
            None
        };

        symbols.push(make_symbol(
            &format!("ts_func_{}", id_counter),
            &name,
            uri,
            if container.is_some() {
                METHOD
            } else {
                FUNCTION
            },
            container,
        ));
        id_counter += 1;
    }

    // Generate classes (25% of symbols)
    let class_count = count * 25 / 100;
    for i in 0..class_count {
        let base_name = TS_CLASS_NAMES[i % TS_CLASS_NAMES.len()];
        let suffix = if i >= TS_CLASS_NAMES.len() {
            format!("{}", i / TS_CLASS_NAMES.len())
        } else {
            String::new()
        };
        let name = format!("{}{}", base_name, suffix);

        symbols.push(make_symbol(
            &format!("ts_class_{}", id_counter),
            &name,
            uri,
            CLASS,
            None,
        ));
        id_counter += 1;
    }

    // Generate interfaces (15% of symbols)
    let remaining = count - func_count - class_count;
    for i in 0..remaining {
        let prefix = TS_INTERFACE_PREFIXES[i % TS_INTERFACE_PREFIXES.len()];
        let base_name = TS_INTERFACE_NAMES[i % TS_INTERFACE_NAMES.len()];
        let name = format!("{}{}", prefix, base_name);

        symbols.push(make_symbol(
            &format!("ts_iface_{}", id_counter),
            &name,
            uri,
            INTERFACE,
            None,
        ));
        id_counter += 1;
    }

    symbols
}

// Go naming patterns
const GO_EXPORTED_FUNCTIONS: &[&str] = &[
    "Fetch",
    "Parse",
    "Handle",
    "Validate",
    "Transform",
    "Process",
    "Create",
    "Update",
    "Delete",
    "Get",
    "Set",
    "New",
    "Load",
    "Save",
    "Compute",
    "Calculate",
    "Format",
    "Serialize",
    "Deserialize",
    "Encode",
    "Decode",
    "Convert",
];

const GO_PRIVATE_FUNCTIONS: &[&str] = &[
    "fetch",
    "parse",
    "handle",
    "validate",
    "transform",
    "process",
    "create",
    "update",
    "delete",
    "get",
    "set",
    "init",
    "load",
    "save",
    "compute",
    "calculate",
];

const GO_FUNCTION_SUFFIXES: &[&str] = &[
    "Data", "Response", "Request", "Error", "Input", "Output", "Result", "Config", "State",
    "Payload", "Message", "Event", "User", "Item", "Node", "Element",
];

const GO_TYPE_NAMES: &[&str] = &[
    "UserService",
    "APIClient",
    "DataProcessor",
    "ConfigManager",
    "StateManager",
    "EventHandler",
    "RequestHandler",
    "ResponseParser",
    "CacheManager",
    "Logger",
    "Database",
    "Connection",
    "Session",
    "AuthProvider",
    "Validator",
];

const GO_INTERFACE_SUFFIXES: &[&str] = &[
    "Fetcher",
    "Parser",
    "Handler",
    "Validator",
    "Transformer",
    "Processor",
    "Creator",
    "Reader",
    "Writer",
    "Logger",
    "Client",
    "Server",
];

/// Generate Go-style symbols.
///
/// Patterns:
/// - Exported functions: PascalCase (FetchData, ParseResponse)
/// - Private functions: camelCase (fetchData, parseResponse)
/// - Types: PascalCase (UserService, APIClient)
/// - Interfaces: -er suffix (Fetcher, Parser, Handler)
pub fn go_symbols(uri: &str, count: usize) -> Vec<Symbol> {
    let mut symbols = Vec::with_capacity(count);
    let mut id_counter = 0;

    // Generate exported functions (40% of symbols)
    let exported_count = count * 4 / 10;
    for i in 0..exported_count {
        let prefix = GO_EXPORTED_FUNCTIONS[i % GO_EXPORTED_FUNCTIONS.len()];
        let suffix =
            GO_FUNCTION_SUFFIXES[(i / GO_EXPORTED_FUNCTIONS.len()) % GO_FUNCTION_SUFFIXES.len()];
        let name = format!("{}{}", prefix, suffix);

        symbols.push(make_symbol(
            &format!("go_exported_{}", id_counter),
            &name,
            uri,
            FUNCTION,
            None,
        ));
        id_counter += 1;
    }

    // Generate private functions (30% of symbols)
    let private_count = count * 3 / 10;
    for i in 0..private_count {
        let prefix = GO_PRIVATE_FUNCTIONS[i % GO_PRIVATE_FUNCTIONS.len()];
        let suffix =
            GO_FUNCTION_SUFFIXES[(i / GO_PRIVATE_FUNCTIONS.len()) % GO_FUNCTION_SUFFIXES.len()];
        let name = format!("{}{}", prefix, suffix);

        let container = if i % 4 == 0 {
            Some(GO_TYPE_NAMES[i % GO_TYPE_NAMES.len()])
        } else {
            None
        };

        symbols.push(make_symbol(
            &format!("go_private_{}", id_counter),
            &name,
            uri,
            if container.is_some() {
                METHOD
            } else {
                FUNCTION
            },
            container,
        ));
        id_counter += 1;
    }

    // Generate types/structs (20% of symbols)
    let type_count = count * 2 / 10;
    for i in 0..type_count {
        let base_name = GO_TYPE_NAMES[i % GO_TYPE_NAMES.len()];
        let suffix = if i >= GO_TYPE_NAMES.len() {
            format!("{}", i / GO_TYPE_NAMES.len())
        } else {
            String::new()
        };
        let name = format!("{}{}", base_name, suffix);

        symbols.push(make_symbol(
            &format!("go_type_{}", id_counter),
            &name,
            uri,
            STRUCT,
            None,
        ));
        id_counter += 1;
    }

    // Generate interfaces (10% of symbols)
    let remaining = count - exported_count - private_count - type_count;
    for i in 0..remaining {
        let suffix = GO_INTERFACE_SUFFIXES[i % GO_INTERFACE_SUFFIXES.len()];
        let prefix =
            GO_FUNCTION_SUFFIXES[i / GO_INTERFACE_SUFFIXES.len() % GO_FUNCTION_SUFFIXES.len()];
        let name = format!("{}{}", prefix, suffix);

        symbols.push(make_symbol(
            &format!("go_iface_{}", id_counter),
            &name,
            uri,
            INTERFACE,
            None,
        ));
        id_counter += 1;
    }

    symbols
}

// Lua naming patterns
const LUA_FUNCTION_VERBS: &[&str] = &[
    "fetch",
    "parse",
    "handle",
    "validate",
    "transform",
    "process",
    "create",
    "update",
    "delete",
    "get",
    "set",
    "init",
    "load",
    "save",
    "render",
    "compute",
];

const LUA_FUNCTION_NOUNS: &[&str] = &[
    "data", "response", "request", "error", "input", "output", "result", "config", "state",
    "props", "context", "payload", "message", "event", "user", "item",
];

const LUA_MODULE_NAMES: &[&str] = &[
    "M", "config", "utils", "helpers", "init", "setup", "api", "client",
];

const LUA_METHOD_NAMES: &[&str] = &[
    "setup",
    "init",
    "run",
    "start",
    "stop",
    "load",
    "save",
    "execute",
    "handle_request",
    "process_data",
    "validate_input",
    "format_output",
];

/// Generate Lua-style symbols.
///
/// Patterns:
/// - Functions: snake_case (fetch_data, parse_response)
/// - Module methods: M.setup, M.init, config.load
/// - Local functions: snake_case with local prefix
pub fn lua_symbols(uri: &str, count: usize) -> Vec<Symbol> {
    let mut symbols = Vec::with_capacity(count);
    let mut id_counter = 0;

    // Generate standalone functions (50% of symbols)
    let func_count = count / 2;
    for i in 0..func_count {
        let verb = LUA_FUNCTION_VERBS[i % LUA_FUNCTION_VERBS.len()];
        let noun = LUA_FUNCTION_NOUNS[(i / LUA_FUNCTION_VERBS.len()) % LUA_FUNCTION_NOUNS.len()];
        let name = format!("{}_{}", verb, noun);

        symbols.push(make_symbol(
            &format!("lua_func_{}", id_counter),
            &name,
            uri,
            FUNCTION,
            None,
        ));
        id_counter += 1;
    }

    // Generate module methods (35% of symbols)
    let method_count = count * 35 / 100;
    for i in 0..method_count {
        let module = LUA_MODULE_NAMES[i % LUA_MODULE_NAMES.len()];
        let method = LUA_METHOD_NAMES[(i / LUA_MODULE_NAMES.len()) % LUA_METHOD_NAMES.len()];
        let name = format!("{}.{}", module, method);

        symbols.push(make_symbol(
            &format!("lua_method_{}", id_counter),
            &name,
            uri,
            METHOD,
            Some(module),
        ));
        id_counter += 1;
    }

    // Generate local functions (15% of symbols)
    let remaining = count - func_count - method_count;
    for i in 0..remaining {
        let verb = LUA_FUNCTION_VERBS[i % LUA_FUNCTION_VERBS.len()];
        let noun = LUA_FUNCTION_NOUNS[(i / LUA_FUNCTION_VERBS.len()) % LUA_FUNCTION_NOUNS.len()];
        let name = format!("_{}_{}", verb, noun);

        symbols.push(make_symbol(
            &format!("lua_local_{}", id_counter),
            &name,
            uri,
            FUNCTION,
            None,
        ));
        id_counter += 1;
    }

    symbols
}

/// Language type for workspace generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Language {
    TypeScript,
    Go,
    Lua,
}

impl Language {
    pub fn extension(&self) -> &'static str {
        match self {
            Language::TypeScript => "ts",
            Language::Go => "go",
            Language::Lua => "lua",
        }
    }

    pub fn generate_symbols(&self, uri: &str, count: usize) -> Vec<Symbol> {
        match self {
            Language::TypeScript => typescript_symbols(uri, count),
            Language::Go => go_symbols(uri, count),
            Language::Lua => lua_symbols(uri, count),
        }
    }
}

/// Generate a realistic mixed-language workspace.
///
/// Creates files with a distribution of:
/// - 50% TypeScript files
/// - 30% Go files
/// - 20% Lua files
pub fn generate_workspace(
    file_count: usize,
    symbols_per_file: usize,
) -> Vec<(String, Vec<Symbol>)> {
    let mut workspace = Vec::with_capacity(file_count);

    for i in 0..file_count {
        let (lang, weight) = {
            let mod_val = i % 10;
            if mod_val < 5 {
                (Language::TypeScript, 0.5)
            } else if mod_val < 8 {
                (Language::Go, 0.3)
            } else {
                (Language::Lua, 0.2)
            }
        };

        let uri = format!("file:///src/file_{}.{}", i, lang.extension());
        let symbol_count = ((symbols_per_file as f64) * (0.8 + weight * 0.4)) as usize;
        let symbols = lang.generate_symbols(&uri, symbol_count);

        workspace.push((uri, symbols));
    }

    workspace
}

#[cfg(test)]
mod tests {

    #[test]
    fn test_typescript_symbols_count() {
        let symbols = typescript_symbols("file:///test.ts", 100);
        assert_eq!(symbols.len(), 100);
    }

    #[test]
    fn test_go_symbols_count() {
        let symbols = go_symbols("file:///test.go", 100);
        assert_eq!(symbols.len(), 100);
    }

    #[test]
    fn test_lua_symbols_count() {
        let symbols = lua_symbols("file:///test.lua", 100);
        assert_eq!(symbols.len(), 100);
    }

    #[test]
    fn test_workspace_generation() {
        let workspace = generate_workspace(10, 50);
        assert_eq!(workspace.len(), 10);

        for (uri, symbols) in &workspace {
            assert!(!symbols.is_empty());
            assert!(uri.starts_with("file:///src/"));
        }
    }

    #[test]
    fn test_typescript_naming_patterns() {
        let symbols = typescript_symbols("file:///test.ts", 20);

        // Check that we have some camelCase functions
        let func_names: Vec<&str> = symbols
            .iter()
            .filter(|s| s.kind == FUNCTION || s.kind == METHOD)
            .map(|s| s.name.as_str())
            .collect();

        assert!(!func_names.is_empty());

        // Functions should be camelCase
        for name in &func_names {
            let first_char = name.chars().next().unwrap();
            assert!(
                first_char.is_lowercase(),
                "Function {} should start with lowercase",
                name
            );
        }
    }

    #[test]
    fn test_go_naming_patterns() {
        let symbols = go_symbols("file:///test.go", 20);

        // Check that we have both exported and private functions
        let func_names: Vec<&str> = symbols
            .iter()
            .filter(|s| s.kind == FUNCTION)
            .map(|s| s.name.as_str())
            .collect();

        let has_exported = func_names
            .iter()
            .any(|n| n.chars().next().unwrap().is_uppercase());
        let has_private = func_names
            .iter()
            .any(|n| n.chars().next().unwrap().is_lowercase());

        assert!(has_exported, "Should have exported functions");
        assert!(has_private, "Should have private functions");
    }

    #[test]
    fn test_lua_naming_patterns() {
        let symbols = lua_symbols("file:///test.lua", 20);

        // Check that we have snake_case functions
        let func_names: Vec<&str> = symbols
            .iter()
            .filter(|s| s.kind == FUNCTION)
            .map(|s| s.name.as_str())
            .collect();

        assert!(!func_names.is_empty());

        // Functions should be snake_case or _prefixed
        for name in &func_names {
            let has_underscore = name.contains('_');
            assert!(
                has_underscore,
                "Function {} should contain underscore",
                name
            );
        }
    }
}
