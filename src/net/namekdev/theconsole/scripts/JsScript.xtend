package net.namekdev.theconsole.scripts

import net.namekdev.theconsole.scripts.JsScript.Context
import net.namekdev.theconsole.scripts.base.IScript

/**
 * This class doesn't have any intelligence since it's totally managed/modified by {@link JsScriptManager}.
 *
 * @author Namek
 * @see JsScriptManager
 */
public class JsScript implements IScript {
	JsScriptManager manager
	package String name
	package var String code
	Context context


	new(JsScriptManager manager, String name, String code) {
		this.manager = manager
		this.name = name
		this.code = code

		context = new Context()
		context.Storage = manager.createScriptStorage(name)
	}

	override run(String[] args) {
		return manager.runJs(this.code, args, context)
	}

	static class Context {
		public Object Storage
	}
}