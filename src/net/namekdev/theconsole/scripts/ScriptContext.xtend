package net.namekdev.theconsole.scripts

import net.namekdev.theconsole.utils.api.IDatabase.ISectionAccessor

/**
 * Variables available for executed script.
 */
class ScriptContext {
	public val ISectionAccessor Storage


	new(ISectionAccessor storage) {
		this.Storage = storage
	}
}