package net.namekdev.theconsole.commands

import java.util.ArrayList
import java.util.regex.Matcher
import java.util.regex.Pattern
import net.namekdev.theconsole.commands.api.ICommand
import net.namekdev.theconsole.commands.api.ICommandLineHandler
import net.namekdev.theconsole.commands.api.ICommandLineUtils
import net.namekdev.theconsole.scripts.execution.ScriptAssertError
import net.namekdev.theconsole.state.api.IConsoleContext
import net.namekdev.theconsole.utils.PathUtils
import net.namekdev.theconsole.view.api.IConsoleOutput
import net.namekdev.theconsole.view.api.IConsolePromptInput

class CommandLineHandler implements ICommandLineHandler {
	val CommandManager commandManager
	val AliasManager aliasManager

	var IConsoleContext consoleContext
	var IConsolePromptInput consolePrompt
	var IConsoleOutput consoleOutput
	var ICommandLineUtils utils


	val NEW_LINE_CHAR = 10 as char
	val QUOTE = "'".charAt(0)
	val QUOTE_DOUBLE = '"'.charAt(0)
	val BACKQUOTE = '`'.charAt(0)

	val paramRegex = Pattern.compile(
		'''(\d+(\.\d*)?)|([\w:/\\\.]+)|\"([^\"]*)\"|\'([^']*)\'|`([^`]*)`''',
		Pattern.UNICODE_CHARACTER_CLASS
	)

	val commandNames = new ArrayList<String>()

	new(CommandManager commandManager) {
		this.commandManager = commandManager
		this.aliasManager = commandManager.aliases
	}

	override init(IConsoleContext context, ICommandLineUtils utils) {
		this.consoleContext = context
		this.consolePrompt = context.input
		this.consoleOutput = context.output
		this.utils = utils
	}

	override getName() {
		class.name
	}

	override handleCompletion() {
		var enableArgumentCompletion = false

		if (utils.countSpacesInInput() == 0) {
			val completions = tryCompleteCommandName()
			if (completions.size == 1) {
				// add space
				utils.setInput(completions.get(0) + ' ')
			}
		}
		else {
			enableArgumentCompletion = true
		}

		if (enableArgumentCompletion) {
			tryCompleteArgument()
		}
	}

	override handleExecution(String input, ICommandLineUtils utils, IConsoleContext context) {
		val String command = input

		if (command.length > 0) {
			consoleContext.output.addInputEntry(command)
			tryExecuteCommand(command, false)
			return true
		}

		return false
	}

	override dispose() {
		consoleContext = null
		consolePrompt = null
		consoleOutput = null
		utils = null
	}


	def tryCompleteCommandName() {
		val namePart = utils.getInput()

		// search between true commands and command aliases
		commandNames.clear()
		commandNames.ensureCapacity(commandManager.commandCount + aliasManager.aliasCount)
		commandManager.findCommandNamesStartingWith(namePart, commandNames)
		aliasManager.findAliasesStartingWith(namePart, commandNames)

		// Complete this command
		if (commandNames.size == 1) {
			// complete to this one
			val commandName = commandNames.get(0)

			if (!commandName.equals(namePart)) {
				utils.setInput(commandName)
				utils.setInputEntry(null)
			}
		}

		// Complete to the common part and show options to continue
		else if (commandNames.size > 1) {
			val commonPart = findBiggestCommonPart(commandNames)

			if (commonPart.length() > 0 && !utils.getInput().equals(commonPart)) {
				utils.setInput(commonPart)
			}
			else {
				// Present options
				var sb = new StringBuilder('---\n')
				for (var i = 0; i < commandNames.size; i++) {
					sb.append(commandNames.get(i))

					if (i != commandNames.size-1) {
						sb.append(NEW_LINE_CHAR)
					}
				}

				val text = sb.toString()
				utils.setInputEntry(text)
			}

		}

		// Just present command list
		else {
			val allScriptNames = commandManager.getAllScriptNames()
			val allAliasNames = aliasManager.getAllAliasNames()
			commandNames.clear()
			commandNames.addAll(allScriptNames)
			commandNames.addAll(allAliasNames)
			val sortedCommands = commandNames.sort()

			val sb = new StringBuilder('---\n')

			for (var i = 0; i < sortedCommands.size; i++) {
				sb.append(sortedCommands.get(i))

				if (i != sortedCommands.size-1) {
					sb.append(NEW_LINE_CHAR)
				}
			}

			utils.setInputEntry(sb.toString())
		}

		return commandNames
	}

	private def void tryCompleteArgument() {
		val line = utils.getInput()
		val caretPos = utils.inputCursorPosition

		// we will tokenize and gather everything before caret position
		val matcher = paramRegex.matcher(line)
		matcher.region(0, caretPos)

		val tokens = new ArrayList<ArgToken>()

		// first token is supposed to be a command name but don't have to be
		matcher.find()
		val commandName = matcher.group
		val command = commandManager.get(commandName)
		val isCommand = command != null

		if (!isCommand) {
			tokens.add(new ArgToken(matcher))
		}

		while (matcher.find()) {
			tokens.add(new ArgToken(matcher))
		}

		var lastTokensCount = 1
		val completions = new ArrayList<String>
		var ArgToken token = null

		if (tokens.size == 0) {
			val suggestions = command.completeArgument(consoleContext, '-noargs')

			if (suggestions != null) {
				completions.addAll(suggestions)
			}
		}
		else while (completions.size == 0 && lastTokensCount <= tokens.size) {
			token = tokens.stream
				.skip(tokens.size - lastTokensCount)
				.findFirst.get

			val testArg = line.substring(token.pos, caretPos)

			if (isCommand) {
				// first ask command's owner (a module or script) whether it can complete the argument
				val suggestions = command.completeArgument(consoleContext, testArg)

				if (suggestions != null) {
					completions.addAll(suggestions)
				}
			}

			if (completions.length == 0) {
				// no one could complete this argument, maybe it's just a full path?
				completions.addAll(PathUtils.suggestPathCompletion(testArg))
			}

			lastTokensCount++
		}

		var String replaceToApply = null

		if (completions.size == 1) {
			replaceToApply = completions.get(0)
		}
		else if (completions.size > 0) {
			replaceToApply = findBiggestCommonPart(completions)

			// just display as text (for now)
			val text = completions.join('\n')
			utils.setInputEntry(text)
		}

		// perform console input partial replacement
		if (replaceToApply != null) {
			// no token is a case for no text after command name
			val currentLine = if (token != null) line.substring(0, token.pos) else line
			val currentLineEnd = currentLine.charAt(currentLine.length - 1)
			val isArgInQuotes = replaceToApply.contains(' ')
			val afterArgPart = line.substring(caretPos)

			val sb = new StringBuilder(currentLine)

			if (isArgInQuotes) {
				if (currentLineEnd != QUOTE && currentLineEnd != QUOTE_DOUBLE && currentLineEnd != BACKQUOTE) {
					sb.append(BACKQUOTE)
				}
			}

			sb.append(replaceToApply)

			var newCaretPos = sb.length

			if (isArgInQuotes) {
				var appendEndQuote = false

				if (afterArgPart.length != 0) {
					val afterArgBegin = afterArgPart.charAt(0)
					if (afterArgBegin != QUOTE && afterArgBegin != QUOTE_DOUBLE && afterArgBegin != BACKQUOTE) {
						appendEndQuote = true
					}
				}
				else {
					appendEndQuote = true
				}

				if (appendEndQuote) {
					sb.append(BACKQUOTE)
				}
			}

			sb.append(afterArgPart)
			utils.setInput(sb.toString, newCaretPos)
		}
	}

	def void tryExecuteCommand(String fullCommand, boolean ignoreAliases) {
		var runAsJavaScript = false
		val matcher = paramRegex.matcher(fullCommand)

		if (!matcher.find()) {
			// Expression is so weird that cannot be a command, try to run it as JS code.
			runAsJavaScript = true
		}
		else {
			// Read command name
			var commandName = ""
			var commandNameEndIndex = -1

			for (var i = 1; i <= matcher.groupCount(); i++) {
				val group = matcher.group(i)

				if (group != null && group.length() > commandName.length()) {
					commandName = group
					commandNameEndIndex = matcher.end(i)
				}
			}

			// Read command arguments
			val args = new ArrayList<String>()

			while (matcher.find()) {
				var parameterValue = ""

				for (var i = 1; i <= matcher.groupCount(); i++) {
					val group = matcher.group(i)

					if (group != null && group.length() > parameterValue.length()) {
						parameterValue = group
					}
				}

				args.add(parameterValue)
			}

			// Look for command of such name
			var command = commandManager.get(commandName) as ICommand

			if (command != null) {
				// TODO validate arguments here

				var result = null as Object
				try {
					result = command.run(consoleContext, args)
				}
				catch (ScriptAssertError assertion) {
					if (assertion.isError) {
						consoleOutput.addErrorEntry(assertion.text)
					}
					else {
						consoleOutput.addTextEntry(assertion.text)
					}
					result = null
				}

				if (result != null) {
					if (result instanceof Exception) {
						consoleOutput.addErrorEntry(result.toString())
					}
					else {
						consoleOutput.addTextEntry(result + "")
					}
				}
			}
			else if (!ignoreAliases) {
				// There is no script named by `commandName` so look for aliases
				val commandStr = aliasManager.get(commandName)

				if (commandStr != null) {
					val newFullCommand = commandStr + fullCommand.substring(commandNameEndIndex)
					tryExecuteCommand(newFullCommand, true)
				}
				else {
					runAsJavaScript = true
				}
			}
			else {
				runAsJavaScript = true
			}
		}

		if (runAsJavaScript) {
			// script was not found, so try to execute it as pure JavaScript!
			val result = consoleContext.runUnscopedJs(fullCommand) as Object

			if (result instanceof Exception) {
				consoleOutput.addErrorEntry(result.toString())
			}
			else {
				consoleOutput.addTextEntry(result + "")
			}
		}
	}

	def String findBiggestCommonPart(ArrayList<String> names) {
		if (names.size == 1) {
			return names.get(0)
		}
		else if (names.size == 0) {
			return ""
		}

		var charIndex = 0 as int
		var isSearching = true

		// TODO this code sucks even more when Xtend doesn't support continue or break instructions
		// functional approach? go ahead if you like!
		while (isSearching) {
			val firstName = names.get(0)

			if (firstName.length() <= charIndex) {
				isSearching = false
			}
			else {
				val c = Character.toLowerCase(firstName.charAt(charIndex))

				for (var i = 1; isSearching && i < names.size; i++) {
					val name = names.get(i)
					val c2 = Character.toLowerCase(name.charAt(charIndex))

					if (name.length() <= charIndex || !c2.equals(c)) {
						isSearching = false
					}
				}
			}

			if (isSearching) {
				charIndex++
			}
		}

		return names.get(0).substring(0, charIndex)
	}


	private static class ArgToken {
		String text
		int pos
		int end
		int len

		new(Matcher m) {
			text = m.group
			pos = m.start
			end = m.end
			len = end - pos
		}

		override toString() {
			return #[text, pos, end].toString
		}
	}
}