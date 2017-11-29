/**
 * This file is part of DCD, a development tool for the D programming language.
 * Copyright (C) 2014 Brian Schott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module dcd.server.autocomplete.complete;

import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.file;
import std.path;
import std.string;
import std.typecons;

import dcd.server.autocomplete.util;

import dparse.lexer;
import dparse.rollback_allocator;

import dsymbol.builtin.names;
import dsymbol.builtin.symbols;
import dsymbol.conversion;
import dsymbol.modulecache;
import dsymbol.scope_;
import dsymbol.string_interning;
import dsymbol.symbol;

import dcd.common.constants;
import dcd.common.messages;

/**
 * Handles autocompletion
 * Params:
 *     request = the autocompletion request
 * Returns:
 *     the autocompletion response
 */
public AutocompleteResponse complete(const AutocompleteRequest request,
	ref ModuleCache moduleCache)
{
	const(Token)[] tokenArray;
	auto stringCache = StringCache(StringCache.defaultBucketCount);
	auto beforeTokens = getTokensBeforeCursor(request.sourceCode,
		request.cursorPosition, stringCache, tokenArray);
	if (beforeTokens.length >= 2)
	{
		if (beforeTokens[$ - 1] == tok!"(" || beforeTokens[$ - 1] == tok!"["
			|| beforeTokens[$ - 1] == tok!",")
		{
			immutable size_t end = goBackToOpenParen(beforeTokens);
			if (end != size_t.max)
				return parenCompletion(beforeTokens[0 .. end], tokenArray,
					request.cursorPosition, moduleCache);
		}
		else
		{
			ImportKind kind = determineImportKind(beforeTokens);
			if (kind == ImportKind.neither)
			{
				if (beforeTokens.isUdaExpression)
					beforeTokens = beforeTokens[$-1 .. $];
				return dotCompletion(beforeTokens, tokenArray, request.cursorPosition,
					moduleCache);
			}
			else
				return importCompletion(beforeTokens, kind, moduleCache);
		}
	}
	return dotCompletion(beforeTokens, tokenArray, request.cursorPosition, moduleCache);
}

/**
 * Handles dot completion for identifiers and types.
 * Params:
 *     beforeTokens = the tokens before the cursor
 *     tokenArray = all tokens in the file
 *     cursorPosition = the cursor position in bytes
 * Returns:
 *     the autocompletion response
 */
AutocompleteResponse dotCompletion(T)(T beforeTokens, const(Token)[] tokenArray,
	size_t cursorPosition, ref ModuleCache moduleCache)
{
	AutocompleteResponse response;

	// Partial symbol name appearing after the dot character and before the
	// cursor.
	string partial;

	// Type of the token before the dot, or identifier if the cursor was at
	// an identifier.
	IdType significantTokenType;

	if (beforeTokens.length >= 1 && beforeTokens[$ - 1] == tok!"identifier")
	{
		// Set partial to the slice of the identifier between the beginning
		// of the identifier and the cursor. This improves the completion
		// responses when the cursor is in the middle of an identifier instead
		// of at the end
		auto t = beforeTokens[$ - 1];
		if (cursorPosition - t.index >= 0 && cursorPosition - t.index <= t.text.length)
			partial = t.text[0 .. cursorPosition - t.index];
		significantTokenType = tok!"identifier";
		beforeTokens = beforeTokens[0 .. $ - 1];
	}
	else if (beforeTokens.length >= 2 && beforeTokens[$ - 1] == tok!".")
		significantTokenType = beforeTokens[$ - 2].type;
	else
		return response;

	switch (significantTokenType)
	{
	mixin(STRING_LITERAL_CASES);
		foreach (symbol; arraySymbols)
			response.completions ~= makeSymbolCompletionInfo(symbol, symbol.kind);
		response.completionType = CompletionType.identifiers;
		break;
	mixin(TYPE_IDENT_CASES);
	case tok!")":
	case tok!"]":
		auto allocator = scoped!(ASTAllocator)();
		RollbackAllocator rba;
		ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, allocator,
			&rba, cursorPosition, moduleCache);
		scope(exit) pair.destroy();
		response.setCompletions(pair.scope_, getExpression(beforeTokens),
			cursorPosition, CompletionType.identifiers, false, partial);
		break;
	case tok!"(":
	case tok!"{":
	case tok!"[":
	case tok!";":
	case tok!":":
		break;
	default:
		break;
	}
	return response;
}

/**
 * Handles paren completion for function calls and some keywords
 * Params:
 *     beforeTokens = the tokens before the cursor
 *     tokenArray = all tokens in the file
 *     cursorPosition = the cursor position in bytes
 * Returns:
 *     the autocompletion response
 */
AutocompleteResponse parenCompletion(T)(T beforeTokens,
	const(Token)[] tokenArray, size_t cursorPosition, ref ModuleCache moduleCache)
{
	AutocompleteResponse response;
	immutable(ConstantCompletion)[] completions;
	switch (beforeTokens[$ - 2].type)
	{
	case tok!"__traits":
		completions = traits;
		goto fillResponse;
	case tok!"scope":
		completions = scopes;
		goto fillResponse;
	case tok!"version":
		completions = predefinedVersions;
		goto fillResponse;
	case tok!"extern":
		completions = linkages;
		goto fillResponse;
	case tok!"pragma":
		completions = pragmas;
	fillResponse:
		response.completionType = CompletionType.identifiers;
		foreach (completion; completions)
		{
			response.completions ~= AutocompleteResponse.Completion(
				completion.identifier,
				CompletionKind.keyword,
				null, null, 0, // definition, symbol path+location
				completion.ddoc
			);
		}
		break;
	case tok!"characterLiteral":
	case tok!"doubleLiteral":
	case tok!"floatLiteral":
	case tok!"identifier":
	case tok!"idoubleLiteral":
	case tok!"ifloatLiteral":
	case tok!"intLiteral":
	case tok!"irealLiteral":
	case tok!"longLiteral":
	case tok!"realLiteral":
	case tok!"uintLiteral":
	case tok!"ulongLiteral":
	case tok!"this":
	case tok!"super":
	case tok!")":
	case tok!"]":
	mixin(STRING_LITERAL_CASES);
		auto allocator = scoped!(ASTAllocator)();
		RollbackAllocator rba;
		ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, allocator,
			&rba, cursorPosition, moduleCache);
		scope(exit) pair.destroy();
		auto expression = getExpression(beforeTokens[0 .. $ - 1]);
		response.setCompletions(pair.scope_, expression,
			cursorPosition, CompletionType.calltips, beforeTokens[$ - 1] == tok!"[");
		break;
	default:
		break;
	}
	return response;
}

/**
 * Provides autocomplete for selective imports, e.g.:
 * ---
 * import std.algorithm: balancedParens;
 * ---
 */
AutocompleteResponse importCompletion(T)(T beforeTokens, ImportKind kind,
	ref ModuleCache moduleCache)
in
{
	assert (beforeTokens.length >= 2);
}
body
{
	AutocompleteResponse response;
	if (beforeTokens.length <= 2)
		return response;

	size_t i = beforeTokens.length - 1;

	if (kind == ImportKind.normal)
	{

		while (beforeTokens[i].type != tok!"," && beforeTokens[i].type != tok!"import"
				&& beforeTokens[i].type != tok!"=" )
			i--;
		setImportCompletions(beforeTokens[i .. $], response, moduleCache);
		return response;
	}

	loop: while (true) switch (beforeTokens[i].type)
	{
	case tok!"identifier":
	case tok!"=":
	case tok!",":
	case tok!".":
		i--;
		break;
	case tok!":":
		i--;
		while (beforeTokens[i].type == tok!"identifier" || beforeTokens[i].type == tok!".")
			i--;
		break loop;
	default:
		break loop;
	}

	size_t j = i;
	loop2: while (j <= beforeTokens.length) switch (beforeTokens[j].type)
	{
	case tok!":": break loop2;
	default: j++; break;
	}

	if (i >= j)
	{
		warning("Malformed import statement");
		return response;
	}

	immutable string path = beforeTokens[i + 1 .. j]
		.filter!(token => token.type == tok!"identifier")
		.map!(token => cast() token.text)
		.joiner(dirSeparator)
		.text();

	string resolvedLocation = moduleCache.resolveImportLocation(path);
	if (resolvedLocation is null)
	{
		warning("Could not resolve location of ", path);
		return response;
	}
	auto symbols = moduleCache.getModuleSymbol(internString(resolvedLocation));

	import containers.hashset : HashSet;
	HashSet!string h;

	void addSymbolToResponses(const(DSymbol)* sy)
	{
		auto a = DSymbol(sy.name);
		if (!builtinSymbols.contains(&a) && sy.name !is null && !h.contains(sy.name)
				&& !sy.skipOver && sy.name != CONSTRUCTOR_SYMBOL_NAME
				&& isPublicCompletionKind(sy.kind))
		{
			response.completions ~= makeSymbolCompletionInfo(sy, sy.kind);
			h.insert(sy.name);
		}
	}

	foreach (s; symbols.opSlice().filter!(a => !a.skipOver))
	{
		if (s.kind == CompletionKind.importSymbol && s.type !is null)
			foreach (sy; s.type.opSlice().filter!(a => !a.skipOver))
				addSymbolToResponses(sy);
		else
			addSymbolToResponses(s);
	}
	response.completionType = CompletionType.identifiers;
	return response;
}

/**
 * Populates the response with completion information for an import statement
 * Params:
 *     tokens = the tokens after the "import" keyword and before the cursor
 *     response = the response that should be populated
 */
void setImportCompletions(T)(T tokens, ref AutocompleteResponse response,
	ref ModuleCache cache)
{
	response.completionType = CompletionType.identifiers;
	string partial = null;
	if (tokens[$ - 1].type == tok!"identifier")
	{
		partial = tokens[$ - 1].text;
		tokens = tokens[0 .. $ - 1];
	}
	auto moduleParts = tokens.filter!(a => a.type == tok!"identifier").map!("a.text").array();
	string path = buildPath(moduleParts);

	bool found = false;

	foreach (importPath; cache.getImportPaths())
	{
		if (importPath.isFile)
		{
			if (!exists(importPath))
				continue;

			found = true;

			auto n = importPath.baseName(".d").baseName(".di");
			if (isFile(importPath) && (importPath.endsWith(".d") || importPath.endsWith(".di"))
					&& (partial is null || n.startsWith(partial)))
				response.completions ~= AutocompleteResponse.Completion(n, CompletionKind.moduleName, null, importPath, 0);
		}
		else
		{
			string p = buildPath(importPath, path);
			if (!exists(p))
				continue;

			found = true;

			try foreach (string name; dirEntries(p, SpanMode.shallow))
			{
				import std.path: baseName;
				if (name.baseName.startsWith(".#"))
					continue;

				auto n = name.baseName(".d").baseName(".di");
				if (isFile(name) && (name.endsWith(".d") || name.endsWith(".di"))
					&& (partial is null || n.startsWith(partial)))
					response.completions ~= AutocompleteResponse.Completion(n, CompletionKind.moduleName, null, name, 0);
				else if (isDir(name))
				{
					if (n[0] != '.' && (partial is null || n.startsWith(partial)))
					{
						immutable packageDPath = buildPath(name, "package.d");
						immutable packageDIPath = buildPath(name, "package.di");
						immutable packageD = exists(packageDPath);
						immutable packageDI = exists(packageDIPath);
						immutable kind = packageD || packageDI ? CompletionKind.moduleName : CompletionKind.packageName;
						immutable file = packageD ? packageDPath : packageDI ? packageDIPath : name;
						response.completions ~= AutocompleteResponse.Completion(n, kind, null, file, 0);
					}
				}
			}
			catch(FileException)
			{
				warning("Cannot access import path: ", importPath);
			}
		}
	}
	if (!found)
		warning("Could not find ", moduleParts);
}

/**
 *
 */
void setCompletions(T)(ref AutocompleteResponse response,
	Scope* completionScope, T tokens, size_t cursorPosition,
	CompletionType completionType, bool isBracket = false, string partial = null)
{
	static void addSymToResponse(const(DSymbol)* s, ref AutocompleteResponse r, string p,
		size_t[] circularGuard = [])
	{
		if (circularGuard.canFind(cast(size_t) s))
			return;
		foreach (sym; s.opSlice())
		{
			if (sym.name !is null && sym.name.length > 0 && isPublicCompletionKind(sym.kind)
				&& (p is null ? true : toUpper(sym.name.data).startsWith(toUpper(p)))
				&& !r.completions.canFind!(a => a.identifier == sym.name)
				&& sym.name[0] != '*')
			{
				r.completions ~= makeSymbolCompletionInfo(sym, sym.kind);
			}
			if (sym.kind == CompletionKind.importSymbol && !sym.skipOver && sym.type !is null)
				addSymToResponse(sym.type, r, p, circularGuard ~ (cast(size_t) s));
		}
	}

	// Handle the simple case where we get all symbols in scope and filter it
	// based on the currently entered text.
	if (partial !is null && tokens.length == 0)
	{
		auto currentSymbols = completionScope.getSymbolsInCursorScope(cursorPosition);
		foreach (s; currentSymbols.filter!(a => isPublicCompletionKind(a.kind)
				&& toUpper(a.name.data).startsWith(toUpper(partial))))
		{
			response.completions ~= makeSymbolCompletionInfo(s, s.kind);
		}
		response.completionType = CompletionType.identifiers;
		return;
	}

	if (tokens.length == 0)
		return;

	DSymbol*[] symbols = getSymbolsByTokenChain(completionScope, tokens,
		cursorPosition, completionType);

	if (symbols.length == 0)
		return;

	if (completionType == CompletionType.identifiers)
	{
		while (symbols[0].qualifier == SymbolQualifier.func
				|| symbols[0].kind == CompletionKind.functionName
				|| symbols[0].kind == CompletionKind.importSymbol
				|| symbols[0].kind == CompletionKind.aliasName)
		{
			symbols = symbols[0].type is null || symbols[0].type is symbols[0] ? []
				: [symbols[0].type];
			if (symbols.length == 0)
				return;
		}
		addSymToResponse(symbols[0], response, partial);
		response.completionType = CompletionType.identifiers;
	}
	else if (completionType == CompletionType.calltips)
	{
		//trace("Showing call tips for ", symbols[0].name, " of kind ", symbols[0].kind);
		if (symbols[0].kind != CompletionKind.functionName
			&& symbols[0].callTip is null)
		{
			if (symbols[0].kind == CompletionKind.aliasName)
			{
				if (symbols[0].type is null || symbols[0].type is symbols[0])
					return;
				symbols = [symbols[0].type];
			}
			if (symbols[0].kind == CompletionKind.variableName)
			{
				auto dumb = symbols[0].type;
				if (dumb !is null)
				{
					if (dumb.kind == CompletionKind.functionName)
					{
						symbols = [dumb];
						goto setCallTips;
					}
					if (isBracket)
					{
						auto index = dumb.getPartsByName(internString("opIndex"));
						if (index.length > 0)
						{
							symbols = index;
							goto setCallTips;
						}
					}
					auto call = dumb.getPartsByName(internString("opCall"));
					if (call.length > 0)
					{
						symbols = call;
						goto setCallTips;
					}
				}
			}
			if (symbols[0].kind == CompletionKind.structName
				|| symbols[0].kind == CompletionKind.className)
			{
				auto constructor = symbols[0].getPartsByName(CONSTRUCTOR_SYMBOL_NAME);
				if (constructor.length == 0)
				{
					// Build a call tip out of the struct fields
					if (symbols[0].kind == CompletionKind.structName)
					{
						response.completionType = CompletionType.calltips;
						response.completions = [generateStructConstructorCalltip(symbols[0])];
						return;
					}
				}
				else
				{
					symbols = constructor;
					goto setCallTips;
				}
			}
		}
	setCallTips:
		response.completionType = CompletionType.calltips;
		foreach (symbol; symbols)
		{
			if (symbol.kind != CompletionKind.aliasName && symbol.callTip !is null)
			{
				auto completion = makeSymbolCompletionInfo(symbol, char.init);
				// TODO: put return type
				response.completions ~= completion;
			}
		}
	}
}

AutocompleteResponse.Completion generateStructConstructorCalltip(const DSymbol* symbol)
in
{
	assert(symbol.kind == CompletionKind.structName);
}
body
{
	string generatedStructConstructorCalltip = "this(";
	const(DSymbol)*[] fields = symbol.opSlice().filter!(
		a => a.kind == CompletionKind.variableName).map!(a => cast(const(DSymbol)*) a).array();
	fields.sort!((a, b) => a.location < b.location);
	foreach (i, field; fields)
	{
		if (field.kind != CompletionKind.variableName)
			continue;
		i++;
		if (field.type !is null)
		{
			generatedStructConstructorCalltip ~= field.type.name;
			generatedStructConstructorCalltip ~= " ";
		}
		generatedStructConstructorCalltip ~= field.name;
		if (i < fields.length)
			generatedStructConstructorCalltip ~= ", ";
	}
	generatedStructConstructorCalltip ~= ")";
	auto completion = makeSymbolCompletionInfo(symbol, char.init);
	completion.identifier = "this";
	completion.definition = generatedStructConstructorCalltip;
	return completion;
}
