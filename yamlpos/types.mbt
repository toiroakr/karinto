///|
/// Source range carried by every CST and AST node.
///
/// Mirrors eemeli/yaml's `range: [start, valueEnd, nodeEnd]` convention where
/// all three are UTF-16 code-unit offsets into the original source string:
/// - `start`: offset of the first character of the node
/// - `value_end`: offset just past the node's value
/// - `node_end`: offset just past the node including trailing whitespace/comment
pub(all) struct Range {
  start : Int
  value_end : Int
  node_end : Int
} derive(Eq, Debug)

///|
pub fn Range::new(start : Int, value_end : Int, node_end : Int) -> Range {
  { start, value_end, node_end }
}

///|
/// The composed YAML AST value node.
///
/// Each node carries its source `range`. Scalars carry the decoded MoonBit
/// value (`ScalarValue`); collections carry their child nodes.
pub(all) enum Node {
  /// A scalar with a decoded value and the original source style.
  Scalar(
    ScalarValue,
    style~ : ScalarStyle,
    range~ : Range,
    tag~ : String?,
    anchor~ : String?
  )
  /// A block or flow mapping. Entries preserve insertion order.
  Mapping(
    Array[(Node, Node)],
    range~ : Range,
    tag~ : String?,
    anchor~ : String?
  )
  /// A block or flow sequence.
  Sequence(Array[Node], range~ : Range, tag~ : String?, anchor~ : String?)
  /// An alias `*a` resolved to the node it points at. `range` is the alias
  /// token range. `resolved` is `false` when the referenced anchor was not yet
  /// defined at the point the alias appeared (forward / self reference), which
  /// the value layer renders as `BadValue`.
  Alias(name~ : String, range~ : Range, resolved~ : Bool)
} derive(Debug)

///|
/// Decoded scalar value following the YAML 1.2 core schema.
pub(all) enum ScalarValue {
  Null
  Bool(Bool)
  Int(Int64)
  Float(Double, repr~ : String)
  Str(String)
  /// A value that failed explicit-tag coercion (e.g. `!!int string`). Mirrors
  /// the reference parser's `BadValue`.
  Bad
} derive(Eq, Debug)

///|
/// Scalar presentation style, preserved from the CST.
pub(all) enum ScalarStyle {
  Plain
  SingleQuoted
  DoubleQuoted
  Literal // |
  Folded // >
} derive(Eq, Debug)

///|
/// A composed document: its root node plus its own source range.
pub(all) struct Document {
  root : Node?
  range : Range
  errors : Array[YamlError]
} derive(Debug)

///|
pub(all) struct YamlError {
  message : String
  offset : Int
} derive(Eq, Debug)

///| Accessors -----------------------------------------------------------------

///|
/// Returns the source range of any node.
pub fn Node::range(self : Node) -> Range {
  match self {
    Scalar(_, range~, ..) => range
    Mapping(_, range~, ..) => range
    Sequence(_, range~, ..) => range
    Alias(range~, ..) => range
  }
}

///|
/// Returns the resolved tag of a node, if any.
pub fn Node::tag(self : Node) -> String? {
  match self {
    Scalar(_, tag~, ..) => tag
    Mapping(_, tag~, ..) => tag
    Sequence(_, tag~, ..) => tag
    Alias(..) => None
  }
}
