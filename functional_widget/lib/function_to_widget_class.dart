import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:functional_widget/src/parameters.dart';
import 'package:functional_widget/src/utils.dart';
import 'package:functional_widget_annotation/functional_widget_annotation.dart';
import 'package:source_gen/source_gen.dart';

const _kFlutterWidgetsPath = 'package:flutter/material.dart';
const _kHookWidgetsPath = 'package:flutter_hooks/flutter_hooks.dart';

final _widgetRef = refer('Widget', _kFlutterWidgetsPath);
final _statelessWidgetRef = refer('StatelessWidget', _kFlutterWidgetsPath);
final _hookWidgetRef = refer('HookWidget', _kHookWidgetsPath);
final _keyRef = refer('Key', _kFlutterWidgetsPath);
final _buildContextRef = refer('BuildContext', _kFlutterWidgetsPath);

String _toTitle(String string) {
  return string.replaceFirstMapped(RegExp('[a-zA-Z]'), (match) {
    return match.group(0).toUpperCase();
  });
}

const _kOverrideDecorator = CodeExpression(Code('override'));

/// A generator that outputs widgets from a function
///
/// The function must be decorated by `@widget` and be a top level function.
/// The type of the widget is infered by the arguments of the function and defaults
/// to `StatelessWidget`
class FunctionalWidgetGenerator
    extends GeneratorForAnnotation<FunctionalWidget> {
  FunctionalWidgetGenerator([FunctionalWidget options])
      : _defaultOptions = FunctionalWidget(
          debugFillProperties: options?.debugFillProperties ?? false,
          equality: options?.equality ?? FunctionalWidgetEquality.none,
          widgetType: options?.widgetType ?? FunctionalWidgetType.stateless,
        );

  final FunctionalWidget _defaultOptions;
  final _emitter = DartEmitter();

  @override
  String generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) {
    final function = _checkValidElement(element);
    final type = parseFunctionalWidgetAnnotation(annotation);

    return _makeClassFromFunctionElement(function, type)
        .accept(_emitter)
        .toString();
  }

  FunctionElement _checkValidElement(Element element) {
    if (element is! FunctionElement) {
      throw InvalidGenerationSourceError(
        'Error, the decorated element is not a function',
        element: element,
      );
    }
    var function = element as FunctionElement;
    if (function.isAsynchronous ||
        function.isExternal ||
        function.isGenerator) {
      throw InvalidGenerationSourceError(
        'Invalid prototype. The function must be synchronous, top level, and return a Widget',
        element: function,
      );
    }
    if (function.returnType != null &&
        !function.returnType.isDynamic &&
        !function.returnType.isUndefined &&
        function.returnType?.displayName != 'Widget') {
      throw InvalidGenerationSourceError(
        'Invalid prototype. The function must return a Widget or be dynamic',
        element: function,
      );
    }
    final className = _toTitle(function.name);
    if (className == function.name) {
      throw InvalidGenerationSourceError(
        'The function name must start with a lowercase',
        element: function,
      );
    }
    return function;
  }

  Spec _makeClassFromFunctionElement(
      FunctionElement functionElement, FunctionalWidget annotation) {
    final parameters = FunctionParameters.parseFunctionElement(functionElement);

    final userDefined = parameters.userDefined;
    final positional = _computeBuildPositionalParametersExpression(parameters);
    final named = _computeBuildNamedParametersExpression(parameters);

    return Class(
      (b) {
        final widgetType = annotation.widgetType ?? _defaultOptions.widgetType;
        b
          ..name = _toTitle(functionElement.name)
          ..types.addAll(
              _parseTypeParemeters(functionElement.typeParameters).toList())
          ..extend = widgetType == FunctionalWidgetType.hook
              ? _hookWidgetRef
              : _statelessWidgetRef
          ..fields.addAll(_paramsToFields(userDefined,
              doc: functionElement.documentationComment))
          ..constructors.add(_getConstructor(userDefined,
              doc: functionElement.documentationComment))
          ..methods.add(_createBuildMethod(
              functionElement.displayName, positional, named, functionElement));
        if (functionElement.documentationComment != null) {
          b.docs.add(functionElement.documentationComment);
        }
        _generateEquality(annotation, userDefined, b, functionElement);
        if (annotation.debugFillProperties ??
            _defaultOptions.debugFillProperties) {
          final overrideDebugFillProperties = _overrideDebugFillProperties(
              userDefined, functionElement.parameters);
          if (overrideDebugFillProperties != null)
            b.methods.add(overrideDebugFillProperties);
        }
      },
    );
  }

  void _generateEquality(
    FunctionalWidget annotation,
    List<Parameter> userDefined,
    ClassBuilder classBuilder,
    FunctionElement functionElement,
  ) {
    final equality = annotation.equality ?? _defaultOptions.equality;
    if (equality != FunctionalWidgetEquality.none) {
      final overrideHashCode = _overrideHashCode(userDefined);
      if (overrideHashCode != null) classBuilder.methods.add(overrideHashCode);

      final operatorEqual = _overrideOperatorEqual(
        userDefined,
        _toTitle(functionElement.name),
        functionElement.typeParameters,
        equality,
      );
      if (operatorEqual != null) classBuilder.methods.add(operatorEqual);
    }
  }

  Map<String, Expression> _computeBuildNamedParametersExpression(
      FunctionParameters parameters) {
    final named = <String, Expression>{};
    for (final p in parameters.userDefined.where((p) => p.named)) {
      named[p.name] = CodeExpression(Code(p.name));
    }
    return named;
  }

  List<Expression> _computeBuildPositionalParametersExpression(
      FunctionParameters parameters) {
    final positional = <Expression>[];
    if (parameters.startsWithContext)
      positional.add(const CodeExpression(Code('_context')));
    if (parameters.startsWithKey)
      positional.add(const CodeExpression(Code('key')));
    if (parameters.followedByContext)
      positional.add(const CodeExpression(Code('_context')));
    if (parameters.followedByKey)
      positional.add(const CodeExpression(Code('key')));
    positional.addAll(parameters.userDefined
        .where((p) => !p.named)
        .map((p) => CodeExpression(Code(p.name))));
    return positional;
  }

  Method _overrideDebugFillProperties(
      List<Parameter> userFields, List<ParameterElement> elements) {
    return userFields.isEmpty
        ? null
        : Method((b) => b
          ..annotations.add(_kOverrideDecorator)
          ..name = 'debugFillProperties'
          ..requiredParameters.add(
            Parameter((b) => b
              ..name = 'properties'
              ..type = refer('DiagnosticPropertiesBuilder')),
          )
          ..returns = refer('void')
          ..lambda = false
          ..body = Block.of(
            [const Code('super.debugFillProperties(properties);')]..addAll(
                userFields.map((f) => _parameterToDiagnostic(
                    f, elements.firstWhere((e) => e.name == f.name)))),
          ));
  }

  Code _parameterToDiagnostic(Parameter parameter, ParameterElement element) {
    String propertyType;
    switch (parameter.type.symbol) {
      case 'int':
        propertyType = 'IntProperty';
        break;
      case 'double':
        propertyType = 'DoubleProperty';
        break;
      case 'String':
        propertyType = 'StringProperty';
        break;
      // TODO: Duration
      default:
        propertyType = element.type != null
            ? _tryParseClassToEnumDiagnostic(element, propertyType) ??
                _tryParseFunctionToDiagnostic(element, propertyType) ??
                _getFallbackElementDiagnostic(element)
            : 'DiagnosticsProperty';
    }

    return Code(
        "properties.add($propertyType('${parameter.name}', ${parameter.name}));");
  }

  String _getFallbackElementDiagnostic(ParameterElement element) =>
      'DiagnosticsProperty<${element.type.isUndefined ? element.computeNode().beginToken : element.type.displayName}>';

  String _tryParseFunctionToDiagnostic(
      ParameterElement element, String propertyType) {
    final kind = element.type.element?.kind;
    if (kind == ElementKind.FUNCTION ||
        kind == ElementKind.FUNCTION_TYPE_ALIAS ||
        kind == ElementKind.GENERIC_FUNCTION_TYPE) {
      // TODO: find a way to remove this dynamic
      propertyType = 'ObjectFlagProperty<dynamic>.has';
    }
    return propertyType;
  }

  String _tryParseClassToEnumDiagnostic(
      ParameterElement element, String propertyType) {
    if (element.type.element is ClassElement) {
      final classElement = element.type.element as ClassElement;
      if (classElement.isEnum) {
        propertyType = 'EnumProperty<${element.type.displayName}>';
      }
    }
    return propertyType;
  }

  Method _overrideOperatorEqual(
    List<Parameter> userFields,
    String className,
    List<TypeParameterElement> typeParameters,
    FunctionalWidgetEquality equality,
  ) {
    return userFields.isEmpty
        ? null
        : Method(
            (b) {
              final serializedTypeParameters = typeParameters.isEmpty
                  ? ''
                  : '<${typeParameters.map((t) => t.displayName).join(', ')}>';
              return b
                ..annotations.add(_kOverrideDecorator)
                ..returns = refer('bool')
                ..name = 'operator=='
                ..lambda = true
                ..requiredParameters.add(
                  Parameter(
                    (b) => b
                      ..name = 'o'
                      ..type = refer('Object'),
                  ),
                )
                ..body = Code(
                    'identical(o, this) || (o is $className$serializedTypeParameters && ${_serializeEquality(userFields, equality)})');
            },
          );
  }

  String _serializeEquality(
      List<Parameter> userFields, FunctionalWidgetEquality equality) {
    switch (equality) {
      case FunctionalWidgetEquality.identical:
        return userFields
            .map((f) => f.name)
            .map((name) => 'identical($name, o.$name)')
            .join(' &&');
      case FunctionalWidgetEquality.equal:
      default:
        return userFields
            .map((f) => f.name)
            .map((name) => '$name == o.$name')
            .join(' &&');
    }
  }

  Method _overrideHashCode(List<Parameter> userFields) {
    return userFields.isEmpty
        ? null
        : Method((b) => b
          ..annotations.add(_kOverrideDecorator)
          ..returns = refer('int')
          ..name = 'hashCode'
          ..type = MethodType.getter
          ..lambda = true
          ..body = userFields.length == 1
              ? Code('${userFields.first.name}.hashCode')
              : Code(
                  'hashValues(${userFields.map((f) => f.name).join(', ')})'));
  }

  Method _createBuildMethod(String functionName, List<Expression> positional,
      Map<String, Expression> named, FunctionElement function) {
    return Method(
      (b) => b
        ..name = 'build'
        ..annotations.add(_kOverrideDecorator)
        ..returns = _widgetRef
        ..requiredParameters.add(
          Parameter((b) => b
            ..name = '_context'
            ..type = _buildContextRef),
        )
        ..body = CodeExpression(Code(functionName))
            .call(
                positional,
                named,
                function.typeParameters
                    ?.map((p) => refer(p.displayName))
                    ?.toList())
            .code,
    );
  }

  Iterable<Reference> _parseTypeParemeters(
    List<TypeParameterElement> typeParameters,
  ) {
    return typeParameters.map((e) {
      return e.bound?.displayName != null
          ? refer('${e.displayName} extends ${e.bound.displayName}')
          : refer(e.displayName);
    });
  }

  Constructor _getConstructor(List<Parameter> fields, {String doc}) {
    return Constructor(
      (b) => b
        ..constant = true
        ..optionalParameters.add(Parameter((b) => b
          ..named = true
          ..name = 'key'
          ..docs.clear()
          ..type = _keyRef))
        ..docs.add(doc ?? '')
        ..requiredParameters
            .addAll(fields.where((p) => !p.named).map((p) => p.rebuild((b) => b
              ..toThis = true
              ..docs.clear()
              ..type = null)))
        ..optionalParameters
            .addAll(fields.where((p) => p.named).map((p) => p.rebuild((b) => b
              ..toThis = true
              ..docs.clear()
              ..type = null)))
        ..initializers.add(const Code('super(key: key)')),
    );
  }

  Iterable<Field> _paramsToFields(List<Parameter> params, {String doc}) sync* {
    for (final param in params) {
      yield Field(
        (b) => b
          ..name = param.name
          ..modifier = FieldModifier.final$
          ..docs.add(doc ?? '')
          ..type = param.type,
      );
    }
  }
}
