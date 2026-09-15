package com.khushi.conduit.core.design

/**
 * Value types for the generated design tokens. The values come from
 * Shared/Design/tokens.json; the app's theme decides how Compose renders them.
 */
data class ColorToken(val light: Long, val dark: Long)

data class TypeRole(val sizeSp: Int, val weight: String)

data class FeatureToken(val id: String, val title: String, val icon: String)
