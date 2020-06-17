# SUBLEQ parser
#
# Copyright (C) 2020 Lawrence Woodman <lwoodman@vlifesystems.com>
# Licensed under an MIT licence.  Please see LICENCE.md for details.


namespace eval parser {
  namespace export {[a-z]*}
}


# TODO: Move away from OO and use dict update and functional style
# parse ?options? filename tokens symbols
#   options:
#     -lpool        Add a literal pool at end of code
proc parser::parse {args} {
  array set options {lpool {}}
  while {[llength $args]} {
    switch -glob -- [lindex $args 0] {
      -lpool {set args [lassign $args options(lpool)]}
      -*     {return -code error "unknown option: [lindex $args 0]"}
      default break
    }
  }
  if {[llength $args] != 3} {
    return -code error "invalid number of arguments"
  }
  lassign $args filename tokens symbols
  set _parser [Parser new $filename $tokens 0 {} $symbols]
  return [$_parser parse $options(lpool)]
}


::oo::class create parser::Parser {
  variable filename
  variable tokens
  variable tokenNum
  variable lookahead
  variable pos
  variable code
  variable symbols
  variable macros
  variable errors
  variable listing


  # TODO: Rethink param order
  constructor {_filename _tokens {_pos 0} {_macros {}} {_symbols {}}} {
    set filename $_filename
    set tokens $_tokens
    set tokenNum 0
    lassign $tokens lookahead
    set pos $_pos
    set code {}
    set macros $_macros
    set symbols $_symbols
    set errors {}
    set listing {}
  }


  # parse ?-lpool?
  #   -lpool    Add a literal pool at end of code
  method parse {{lpoolOpt {}}} {
    if {$lpoolOpt ne "" && $lpoolOpt ne "-lpool"} {
      return -code error "Invalid option $lpoolOpt"
    }
    my Block
    if {$lpoolOpt eq "-lpool"} {
      my AddLPool
    }
    return [list $code $macros $symbols $listing $errors]
  }


  # TODO: Work out what to return
  method Block {} {
    while {![my EOF]} {
      lassign $lookahead type val
      switch $type {
        comment {
          my Comment
        }
        directive {
          #TODO: Detect end of block: .endif, .else, .endm, etc
          my Directive
        }
        id {
          my Statement
        }
        label {
          my Label
        }
        default {
          return -code error "unknown type: $type"
        }
      }
    }
  }


  # A label
  # Return: ok: true, error: false
  method Label {} {
    lassign $lookahead type val startLineNum
    set labelToken $lookahead
    if {![my Match -type label]} {return false}
    if {[dict exists $symbols $val]} {
      my Error "Symbol already exists: $val"
      return false
    }
    dict set symbols $val [dict create type label pos $pos]
    my AddListingEntry -lineNum  $startLineNum
    return true
  }


  # A Comment
  method Comment {} {
    # TODO: Is this needed as NextToken should never return a comment
    return [my Match -type comment]
  }


  # A statement
  # This could be an sble instruction or a macro to run
  method Statement {} {
    lassign $lookahead type val
    if {$val eq "sble"} {
      return [my Sble]
    }
    # Must be a macro
    return [my RunMacro]
  }


  # A sble instruction
  # Return: ok: true, error: false
  method Sble {} {
    lassign $lookahead - - startLineNum
    if {![my Match -type id -val "sble"]} {return false}
    lassign $lookahead - val
    set a $val
    if {![my Match -type {id expr num literal} -lineNum $startLineNum]} {
      return false
    }
    lassign $lookahead - val
    set b $val
    if {![my Match -type {id expr num} -lineNum $startLineNum]} {return false}
    lassign $lookahead type val lineNum
    if {![my EOF] && $startLineNum == $lineNum} {
      set c $val
      if {![my Match -type {id expr num} -lineNum $startLineNum]} {
        return false
      }
    } else {
      set c {$+1}
    }
    my AddListingEntry -lineNum  $startLineNum
    my AppendCode [list $a $b $c]
    return true
  }


  # A directive
  # Return: ok: true, error: false
  method Directive {} {
    lassign $lookahead type val
    switch $val {
      .ascii {
        return [my Ascii]
      }
      .asciiz {
        return [my Asciiz]
      }
      .equ {
        return [my Equ]
      }
      .include {
        return [my Include]
      }
      .macro {
        return [my CompileMacro]
      }
      .word {
        return [my Word]
      }
      default {
        my Error "Unknown directive: $val"
        my NextLine
      }
    }
    return true
  }



  # .ascii directive
  # Return: ok: true, error: false
  method Ascii {} {
    lassign $lookahead - - lineNum
    if {![my Match -type directive -val ".ascii"]} {return false}
    lassign $lookahead type val
    if {![my Match -type string -lineNum $lineNum]} {return false}

    my AddListingEntry -lineNum $lineNum
    my AppendCode [my StringToNums $val]
  }


  # .asciiz directive
  # Return: ok: true, error: false
  method Asciiz {} {
    lassign $lookahead - - lineNum
    if {![my Match -type directive -val ".asciiz"]} {return false}
    lassign $lookahead type val
    if {![my Match -type string -lineNum $lineNum]} {return false}

    my AddListingEntry -lineNum $lineNum
    my AppendCode [list {*}[my StringToNums $val] 0]
  }


  # .equ directive
  # Return: ok: true, error: false
  method Equ {} {
    lassign $lookahead - - lineNum
    if {![my Match -type directive -val ".equ"]} {return false}
    lassign $lookahead - name
    if {[dict exists $symbols $name]} {
      my Error "Symbol already exists: $name"
      my NextLine
      return false
    }
    if {![my Match -type id -lineNum $lineNum]} {return false}
    lassign $lookahead - val
    if {![my Match -type num -lineNum $lineNum]} {return false}
    dict set symbols $name [dict create type constant val $val]
    return true
  }
  

  # .include directive
  # Return: ok: true, error: false
  method Include {} {
    lassign $lookahead - - lineNum
    if {![my Match -type directive -val ".include"]} {return false}
    lassign $lookahead type _filename
    if {![my Match -type string -lineNum $lineNum]} {return false}

    try {
      set src [readFile $_filename]
    } on error {err} {
      my Error -lineNum $lineNum "Can't include file: $_filename, $err"
      return false
    }
    my AddListingEntry -lineNum $lineNum
    lassign [lex $_filename $src] incTokens incSymbols incLexErrors
    if {[llength $incLexErrors] > 0} {
      my AddErrors $incErrors
      return false
    }
    
    # Merge literal symbols into symbols
    dict for {name def} $incSymbols {
      set type [dict get $def type]
      if {$type ne "literal"} {
        return -code error "Invalid symbol type from lexer: $type"
      }
      if {![dict exist $symbols $name]} {
        dict set symbols $name $def
      }
    }

    set incParser [
      parser::Parser new $_filename $incTokens $pos $macros $symbols]
    lassign [$incParser parse] incCode macros symbols incListing incErrors
    # TODO: get a listing from this parser prefixed with a filename
    # TODO: and add to existing listing

    if {[llength $incErrors] > 0} {
      my AddErrors $incErrors
      return false
    }

    my AddFileListing $incListing

    set pass2Code [pass2 $incCode $pos $symbols]
    # TODO: Consider -nolist here
    my AppendCode $pass2Code
  }


  # .word directive
  # Return ok: true, error: false
  method Word {} {
    lassign $lookahead - - startLineNum
    if {![my Match -type directive -val ".word"]} {return false}
    set words [list]
    while {![my EOF]} {
      lassign $lookahead type val lineNum
      if {$lineNum != $startLineNum} {
        break
      }
      if {![my Match -type {id num expr}]} {return false}
      lappend words $val
    }
    if {[llength $words] == 0} {
      my Error "Incomplete line"
      my NextLine
      return false
    }
    my AddListingEntry -lineNum $startLineNum
    my AppendCode $words
    return true
  }


  # .macro directive
  # Return ok: true, error: false
  method CompileMacro {} {
    lassign $lookahead - - startLineNum
    lappend openTokens $lookahead
    if {![my Match -type directive -val ".macro"]} {return false}
    lappend openTokens $lookahead
    lassign $lookahead - macroName lineNum
    if {[my Match -type id -lineNum $startLineNum]} {
      if {[dict exists $macros $macroName]} {
        my Error -lineNum $startLineNum "Macro already exists: $macroName"
      }
    }
    # Continue processing regardless of outcome above
    # otherwise stuck in macro body

    # Get parameters
    set macroParams [list]
    while {![my EOF]} {
      lassign $lookahead type val lineNum
      if {$lineNum != $startLineNum} {
        break
      }
      lappend openTokens $lookahead
      if {![my Match -type id]} {return false}
      lappend macroParams $val
    }

    set bodyTokens [list]
    while {![my EOF]} {
      lassign $lookahead type val lineNum
      # TODO: Workout if want to check open .macro statements to allow
      # TODO: for nested macro definitions
      if {$type eq "directive" && $val eq ".endm"} {
        # TODO: Test if first thing on line here or in lexer?
        break
      }
      lappend bodyTokens $lookahead
      # TODO: This strips comments out of body and therefore they
      # TODO: are not included in error lines - should this be
      # TODO: the case?
      my NextToken
    }
    lappend closeTokens $lookahead
    if {![my Match -type directive -val ".endm"]} {return false}

    set macroParser [parser::Parser new $filename $bodyTokens 0 $macros]
    lassign [$macroParser parse] macroCode macroMacros \
            macroSymbols macroListing macroErrors
    if {[llength $macroErrors] > 0} {
      my AddErrors $macroErrors
      return false
    }

    # TODO: Do something with macroMacros?

    set _body [pass2 $macroCode 0 $macroSymbols]
    set macroListing [dict get $macroListing $filename main]
    my AddListingEntry -macro [
      list $macroName $openTokens $macroListing $closeTokens
    ]
    dict set macros $macroName [dict create params $macroParams body $_body]
    return true
  }


  # Run a macro
  # Return ok: true, error: false
  method RunMacro {} {
    lassign $lookahead - macroName startLineNum
    if {![my Match -type id]} {return false}
    if {![dict exists $macros $macroName]} {
      my Error -lineNum $startLineNum "Unknown macro: $macroName"
      my NextLine
      return false
    }

    # Get args
    set macroArgs [list]
    while {![my EOF]} {
      lassign $lookahead type val lineNum
      if {$lineNum != $startLineNum} {
        break
      }
      if {![my Match -type {id expr num literal}]} {return false}
      lappend macroArgs $val
    }

    set macro [dict get $macros $macroName]
    set params [dict get $macro params]
    set body [dict get $macro body]

    if {[llength $params] != [llength $macroArgs]} {
      my Error -lineNum $startLineNum "Wrong number of arguments"
      my NextLine
      return false
    }
    set _labels [dict create]
    for {set i 0} {$i < [llength $macroArgs]} {incr i} {
      dict set _labels [lindex $params $i] [lindex $macroArgs $i]
    }
    my AddListingEntry -lineNum $startLineNum
    # TODO: this needs to be done for each relevant token
    my AppendCode [resolveLabels $body $_labels]
    return true
  }


  method AppendCode {_code} {
    my AddListingEntry -code $_code
    set code [list {*}$code {*}$_code]
    incr pos [llength $_code]
  }


  # Add a literal pool
  method AddLPool {} {
    set literals {}
    dict for {name def} $symbols {
      set type [dict get $def type]
      if {$type eq "literal"} {
        set val [dict get $def val]
        lappend literals [list $name $val]
      }
    }

    # TODO: Put a log or comment entry to say that this is the literal pool
    # TODO: start and end

    # The literals are sorted to make code consistent and
    # easier to test
    set literals [lsort -integer -index 1 $literals]
    foreach lit $literals {
      lassign $lit name val
      dict set symbols $name [dict create type label pos $pos]
      set litTokens [list [list label $name -1] \
                          [list directive .word -1] \
                          [list num $val -1]]
      my AddListingEntry -tokens $litTokens
      my AppendCode [list $val]
    }
  }


  # Convert a string to the ascii numbers for it
  # NOTE: This performs substitution on the string first
  #       to convert \n etc to newlines
  # Return: {nums}
  method StringToNums {str} {
    set str [subst -nocommands -novariables $str]
    return [lmap ch [split $str ""] {scan $ch "%c"}]
  }


  # Return: ok: true, error: false
  method Match {args} {
    array set options {}
    while {[llength $args]} {
      switch -glob -- [lindex $args 0] {
        -type* {set args [lassign $args - options(types)]}
        -val {set args [lassign $args - options(val)]}
        -lineNum {set args [lassign $args - options(lineNum)]}
        -*      {return -code error "unknown option: [lindex $args 0]"}
        default break
      }
    }
    if {[llength $args] > 0} {
      return -code error "invalid number of arguments"
    }

    if {[my EOF]} {
      my Error "End of tokens"
      return false
    }

    lassign $lookahead type val lineNum

    if {[info exists options(lineNum)] && $options(lineNum) != $lineNum} {
      # TODO: Note this will always return wrong line number
      my Error -lineNum $options(lineNum) "Incomplete line"
      return false
    }
    if {[info exists options(types)] && $type ni $options(types) } {
      # TODO: debugging
      my Error "Unexpected type"
      my NextToken
      return false
    }
    if {[info exists options(val)] && $options(val) ne $val} {
      my Error "Expecting value: $wantType, got: $type"
      my NextToken
      return false
    }
    my NextToken
    return true
  }


  # Return: true if End Of File, else false
  method EOF {} {
    if {$tokenNum >= [llength $tokens]} {return true}
    return false
  }


  # TODO: Need to return anything?
  # NextToken
  # Skips comments
  # Return: false if no next token, else true
  method NextToken {{incComments {}}} {
    incr tokenNum
    if {[my EOF]} {
      return false
    }
    set lookahead [lindex $tokens $tokenNum]
    lassign $lookahead type
    if {$type eq "comment"} {my NextToken}
    return true
  }


  # TODO: Need to return anything?
  # Return: false if no next line token, else true
  method NextLine {} {
    lassign $lookahead - - startLineNum
    while {[my NextToken]} {
      lassign $lookahead - - lineNum
      if {$lineNum != $startLineNum} {
        return true
      }
    }
    return false
  }


  method Error {args} {
    lassign $lookahead - - lineNum
    array set options [list lineNum $lineNum]
    while {[llength $args]} {
      switch -glob -- [lindex $args 0] {
        -lineNum {set args [lassign $args - options(lineNum)]}
        -*      {return -code error "unknown option: [lindex $args 0]"}
        default break
      }
    }
    if {[llength $args] != 1} {
      return -code error "invalid number of arguments"
    }

    lassign $args msg

    set line [my GetLine $options(lineNum)]
    lappend errors \
      [dict create filename $filename lineNum $options(lineNum) \
                   line $line msg $msg]
  }


  method AddErrors {newErrors} {
    set errors [list {*}$errors {*}$newErrors]
  }


  method AddFileListing {_listing} {
    dict for {_filename fileListing} $_listing {
      if {![dict exists $listing $_filename]} {
        dict set listing $_filename $fileListing
      }
    }
  }


  method AddListingEntry {args} {
    array set options {}
    while {[llength $args]} {
      switch -glob -- [lindex $args 0] {
        -code {set args [lassign $args - options(code)]}
        -lineNum {set args [lassign $args - options(lineNum)]}
        -macro {set args [lassign $args - options(macro)]}
        -tokens {set args [lassign $args - options(tokens)]}
        -*     {return -code error "unknown option: [lindex $args 0]"}
        default break
      }
    }
    if {[llength $args] != 0} {
      return -code error "invalid number of arguments"
    }
    if {[info exists options(lineNum)] && [info exists options(tokens)]} {
      return -code error "can't use -lineNum and -tokens"
    }
    if {[info exists options(macro)] && [llength [array names options]] > 1} {
      return -code error "can't use -macro with other switches"
    }

    if {[info exists options(macro)]} {
      lassign $options(macro) macroName openTokens macroListing closeTokens
      dict set listing $filename macros $macroName $macroListing
      dict set listing $filename macros $macroName \
                       -1 tokens $openTokens
      dict set listing $filename macros $macroName \
                       -2 tokens $closeTokens
    }
    if {[info exists options(code)]} {
      dict set listing $filename main $pos code $options(code)
    }
    if {[info exists options(lineNum)]} {
      set lineTokens [my GetLineTokens $options(lineNum)]
      dict set listing $filename main $pos tokens $lineTokens
    }
    if {[info exists options(tokens)]} {
      dict set listing $filename main $pos tokens $options(tokens)
    }
  }


  # Get the tokens for the current line
  method GetLineTokens {wantLineNum} {
    set _tokenNum $tokenNum
    for {} {$_tokenNum >= 0} {incr _tokenNum -1} {
      if {$_tokenNum != [llength $tokens]} {
        lassign [lindex $tokens $_tokenNum] type value lineNum
        if {$lineNum < $wantLineNum} {
          break
        }
      }
    }

    # TODO: Work out what happens if at start of tokens
    incr _tokenNum
    set line [list]
    for {} {$_tokenNum < [llength $tokens]} {incr _tokenNum} {
      set token [lindex $tokens $_tokenNum]
      lassign $token type value lineNum
      if {$lineNum != $wantLineNum} {
        break
      }
      lappend line $token
    }
    return $line
  }


  method GetLine {lineNum} {
    set lineTokens [my GetLineTokens $lineNum]
    set line [list]
    foreach token $lineTokens {
      lassign $token type value lineNum
      # TODO: test for comments and strings
      switch $type {
        comment {lappend line "; $value"}
        label {lappend line "$value:"}
        default {lappend line $value}
      }
    }
    return [join $line " "]
  }
}
