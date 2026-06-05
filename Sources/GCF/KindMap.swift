/// Maps full kind names to short GCF abbreviations.
public let kindAbbrev: [String: String] = [
    "function": "fn",
    "type": "type",
    "method": "method",
    "interface": "iface",
    "var": "var",
    "const": "const",
    "resource": "resource",
    "table": "table",
    "class": "class",
    "selector": "selector",
    "field": "field",
    "route_handler": "route",
    "external": "ext",
    "file": "file",
    "package": "pkg",
    "service": "svc",
]

/// Reverse of kindAbbrev: maps abbreviations back to full kind names.
public let kindExpand: [String: String] = [
    "fn": "function",
    "type": "type",
    "method": "method",
    "iface": "interface",
    "var": "var",
    "const": "const",
    "resource": "resource",
    "table": "table",
    "class": "class",
    "selector": "selector",
    "field": "field",
    "route": "route_handler",
    "ext": "external",
    "file": "file",
    "pkg": "package",
    "svc": "service",
]
