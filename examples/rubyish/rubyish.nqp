use NQPHLL;

# Ruby subset extended from the `rubyish` example, as introduced in the
# Edument Rakudo and NQP internals course.

class RubyishClassHOW {
    has $!name;
    has %!methods;

    method new_type(:$name!) {
        nqp::newtype(self.new(:$name), 'HashAttrStore')
    }

    method add_method($obj, $name, $code) {
        if nqp::existskey(%!methods, $name) {
            nqp::die("This class already has a method named " ~ $name);
        }
        %!methods{$name} := $code;
    }

    method find_method($obj, $name) {
        %!methods{$name} // nqp::null();
    }
}

grammar Rubyish::Grammar is HLL::Grammar {

    token TOP {
        :my $*CUR_BLOCK   := QAST::Block.new(QAST::Stmts.new());
        :my $*TOP_BLOCK   := $*CUR_BLOCK;
        :my $*CLASS_BLOCK := $*CUR_BLOCK;
        :my $*IN_TEMPLATE := 0;
        :my $*IN_PARENS   := 0;
        :my %*SYM         := self.sym-init();
        ^ ~ $ <stmtlist>
            || <.panic('Syntax error')>
    }

    token continuation   { \\ \n }
    rule separator       { ';' | \n <!after continuation> }
    token template-chunk { [<tmpl-unesc>|<tmpl-hdr>] ~ [<tmpl-esc>|$] <template-nibble>* }
    proto token template-nibble {*}
    token template-nibble:sym<interp>     { <interp> }
    token template-nibble:sym<stray-tag>  { [<.tmpl-unesc>|<.tmpl-hdr>] <.panic("Stray tag, e.g. '%>' or '<?rbi?>'")> }
    token template-nibble:sym<plain-text> { [<!before [<tmpl-esc>|'#{'|$]> .]+ }

    token tmpl-hdr   {'<?rbi?>' \h* \n? <?{$*IN_TEMPLATE := 1}>}
    token tmpl-esc   {\h* '<%'
                     [<?{$*IN_TEMPLATE}> || <.panic('Template directive precedes "<?rbi?>"')>]
    }
    token tmpl-unesc { '%>' \h* \n?
                     [<?{$*IN_TEMPLATE}> || <.panic('Template directive precedes "<?rbi?>"')>]
    }

    rule stmtlist {
        [ <stmt=.stmtish>? ] *%% [<.separator>|<stmt=.template-chunk>]
    }

    token stmtish {
        <stmt> [:s <modifier> :s <EXPR>]?
    }

    token modifier {if|unless|while|until}

    proto token stmt {*}

    token stmt:sym<def> {
        :my %sym-save := self.hcopy(%*SYM);

        'def' ~ 'end' <defbody>

        <?{%*SYM := self.hcopy(%sym-save);1}>
    }

    rule defbody {
        :my $*CUR_BLOCK := QAST::Block.new(QAST::Stmts.new());
        <operation> ['(' ~ ')' <signature>]? <separator>?
        <stmtlist>
    }

    token comma { :s [','|'=>'] :s }

    rule signature {
        :my $*IN_PARENS := 1; <param>* %% <comma>
    }

    token param { <ident> }

    token stmt:sym<class> {
        :my $*IN_CLASS := 1;
        :my @*METHODS;
        :my %sym-save := self.hcopy(%*SYM);

        [<sym> \h+] ~ [\h* 'end'] <classbody>

        <?{%*SYM := self.hcopy(%sym-save);1}>
    }

    rule classbody {
        :my $*CUR_BLOCK   := QAST::Block.new(QAST::Stmts.new());
        :my $*CLASS_BLOCK := $*CUR_BLOCK;
        <ident> <separator>
        <stmtlist>
    }

    token stmt:sym<EXPR> { <EXPR> }
    token term:sym<assign> { <var> \h* <OPER=infix> '=' \h* <EXPR> }

    token term:sym<call> {
        <!keyword>
        <operation> ['(' ~ ')' <call-args=.paren-args>?
                    | \h* <call-args>? <?{%*SYM{~$<operation>} eq 'def'}> ]
    }

    token term:sym<nqp-op> {
        'nqp:'':'?<ident> ['(' ~ ')' <call-args=.paren-args>? | <call-args>? ]
    }

    token term:sym<quote-words> {
        \% w <?before [.]> <quote_EXPR: ':q', ':w'>
    }

    token call-args  { :s <EXPR>+ % <comma> }
    token paren-args {:my $*IN_PARENS := 1; <call-args> }

    token operation {<ident>[\!|\?]?}

    token term:sym<new> {
        ['new' \h+ :s <ident> | <ident> '.' 'new'] ['(' ~ ')' <call-args=.paren-args>?]?
    }

    token var {
        :my $*MAYBE_DECL := 0;
        [$<sigil>=[\$|\@\@?]|<!keyword>]
        \+?<ident>
        [ <?before \h* '=' [\w | \h+ || <.EXPR>] { $*MAYBE_DECL := 1 }> || <?> ]
    }

    token term:sym<var> { <var> }

    token term:sym<value> { \+? <value> }

    proto token value {*}
    token value:sym<string>  {<strings>}
    token strings            {<string> [\h*<strings>]?}
    token string             { <?[']> <quote_EXPR: ':q'>
                             | <?["]> <quote_EXPR: ':qq'>
                             | \%[ q <?before [.]> <quote_EXPR: ':q'>
                                 | Q <?before [.]> <quote_EXPR: ':qq'>
                                 ]
                             }

    token paren-list {
         :my $*IN_PARENS := 1;
         <EXPR> *%% <comma>
    }

    token value:sym<integer> { \+? \d+ }
    token value:sym<float>   { \+? \d* '.' \d+ }
    token value:sym<array>   {'[' ~ ']' <paren-list> }
    token value:sym<hash>    {'{' ~ '}' <paren-list> }
    token value:sym<nil>     { <sym> }
    token value:sym<true>    { <sym> }
    token value:sym<false>   { <sym> }

    # Interpolation
    token interp      { '#{' ~ '}' [ :s <stmt> :s
                                  || <panic('string interpolation error')>]
                       }
    token quote_escape:sym<#{ }> { <interp>  }

    # Reserved words.
    token keyword {
        [ BEGIN     | class     | ensure    | nil       | new       | when
        | END       | def       | false     | not       | super     | while
        | alias     | defined   | for       | or        | then      | yield
        | and       | do        | if        | redo      | true
        | begin     | else      | in        | rescue    | undef
        | break     | elsif     | module    | retry     | unless
        | case      | end       | next      | return    | until
        ] <!ww>
    }

    proto token comment {*}
    token comment:sym<line>   { '#' [<?{!$*IN_TEMPLATE}> \N* || [<!before <tmpl-unesc>>\N]*] }
    token comment:sym<podish> {[^^'=begin'\n] ~ [^^'=end'\n ] .*?}
    token ws { <!ww> [\h | <.comment> | <.continuation> | <?{$*IN_PARENS}> \n]* }

    INIT {
        # Operator precedence levels
        # see http://www.tutorialspoint.com/ruby/ruby_operators.htm
        # x: **
        Rubyish::Grammar.O(':prec<x=>, :assoc<left>',  '%exponentiation');
        # y: ! ~ + - (unary)
        Rubyish::Grammar.O(':prec<y=>, :assoc<unary>', '%unary');
        # w: * / %
        Rubyish::Grammar.O(':prec<w=>, :assoc<left>',  '%multiplicative');
        # u: + -
        Rubyish::Grammar.O(':prec<u=>, :assoc<left>',  '%additive');
        # t: >> <<
        Rubyish::Grammar.O(':prec<t=>, :assoc<left>',  '%bitshift');
        # s: &
        Rubyish::Grammar.O(':prec<s=>, :assoc<left>',  '%bitand');
        # r: ^ |
        Rubyish::Grammar.O(':prec<r=>, :assoc<left>',  '%bitor');
        # q: <= < > >= le lt gt ge
        Rubyish::Grammar.O(':prec<q=>, :assoc<left>',  '%comparison');
        # n: <=> == === != =~ !~ eq ne cmp
        Rubyish::Grammar.O(':prec<n=>, :assoc<left>',  '%equality');
        # l: &&
        Rubyish::Grammar.O(':prec<l=>, :assoc<left>',  '%logical_and');
        # k: ||
        Rubyish::Grammar.O(':prec<k=>, :assoc<left>',  '%logical_or');
        # q: ?:
        Rubyish::Grammar.O(':prec<g=>, :assoc<right>', '%conditional');
        # f: = %= { /= -= += |= &= >>= <<= *= &&= ||= **=
        Rubyish::Grammar.O(':prec<f=>, :assoc<right>', '%assignment');
        # e: not (unary)
        Rubyish::Grammar.O(':prec<e=>, :assoc<unary>', '%loose_not');
        # c: or and
        Rubyish::Grammar.O(':prec<c=>, :assoc<left>',  '%loose_logical');
    }

    # Operators - mostly stolen from NQP
    token infix:sym<**> { <sym>  <O('%exponentiation, :op<pow_n>')> }

    token prefix:sym<-> { <sym>  <O('%unary, :op<neg_n>')> }
    token prefix:sym<!> { <sym>  <O('%unary, :op<not_i>')> }

    token infix:sym<*>  { <sym> <O('%multiplicative, :op<mul_n>')> }
    token infix:sym</>  { <sym> <O('%multiplicative, :op<div_n>')> }
    token infix:sym<%>  { <sym><![>]> <O('%multiplicative, :op<mod_n>')> }

    token infix:sym<+>  { <sym> <O('%additive, :op<add_n>')> }
    token infix:sym<->  { <sym> <O('%additive, :op<sub_n>')> }
    token infix:sym<~>  { <sym> <O('%additive, :op<concat>')> }

    token infix:sym«<<»   { <sym>  <O('%bitshift, :op<bitshiftl_i>')> }
    token infix:sym«>>»   { <sym>  <O('%bitshift, :op<bitshiftr_i>')> }

    token infix:sym<&>  { <sym> <O('%bitand, :op<bitand_i>')> }
    token infix:sym<|>  { <sym> <O('%bitor,  :op<bitor_i>')> }
    token infix:sym<^>  { <sym> <O('%bitor,  :op<bitxor_i>')> }

    token infix:sym«<=»   { <sym><![>]>  <O('%comparison, :op<isle_n>')> }
    token infix:sym«>=»   { <sym>  <O('%comparison, :op<isge_n>')> }
    token infix:sym«<»    { <sym>  <O('%comparison, :op<islt_n>')> }
    token infix:sym«>»    { <sym>  <O('%comparison, :op<isgt_n>')> }
    token infix:sym«le»   { <sym>  <O('%comparison, :op<isle_s>')> }
    token infix:sym«ge»   { <sym>  <O('%comparison, :op<isge_s>')> }
    token infix:sym«lt»   { <sym>  <O('%comparison, :op<islt_s>')> }
    token infix:sym«gt»   { <sym>  <O('%comparison, :op<isgt_s>')> }

    token infix:sym«==»   { <sym>  <O('%equality, :op<iseq_n>')> }
    token infix:sym«!=»   { <sym>  <O('%equality, :op<isne_n>')> }
    token infix:sym«<=>»  { <sym>  <O('%equality, :op<cmp_n>')> }
    token infix:sym«eq»   { <sym>  <O('%equality, :op<iseq_s>')> }
    token infix:sym«ne»   { <sym>  <O('%equality, :op<isne_s>')> }
    token infix:sym«cmp»  { <sym>  <O('%equality, :op<cmp_s>')> }

    token infix:sym<&&>   { <sym>  <O('%logical_and, :op<if>')> }
    token infix:sym<||>   { <sym>  <O('%logical_or,  :op<unless>')> }

    token infix:sym<? :> { '?' :s <EXPR('i=')>
                           ':' <O('%conditional, :reducecheck<ternary>, :op<if>')>
    }

    token infix:sym<=>  { <sym><![>]> <O('%assignment, :op<bind>')> }

    token prefix:sym<not> { <sym>  <O('%loose_not,     :op<not_i>')> }
    token infix:sym<and>  { <sym>  <O('%loose_logical, :op<if>')> }
    token infix:sym<or>   { <sym>  <O('%loose_logical, :op<unless>')> }
 
    # Parenthesis
    token circumfix:sym<( )> {'(' <EXPR> ')' <O('%methodop')> }

    # Method call
    token postfix:sym<.>  {
        '.' <operation> [ '(' ~ ')' <call-args=.paren-args>? ]?
        <O('%methodop')>
    }

    # Array and hash indices
    token postcircumfix:sym<[ ]> { '[' ~ ']' [ <EXPR> ] <O('%methodop')> }
    token postcircumfix:sym<{ }> { '{' ~ '}' [ <EXPR> ] <O('%methodop')> }
    token postcircumfix:sym<ang> {
        <?[<]> <quote_EXPR: ':q'>
        <O('%methodop')>
    }

    # Statement control
    rule xblock {
        <EXPR> [ <separator> [:s 'then']? | 'then' | <?before <tmpl-unesc>>] <stmtlist>
    }

    token stmt:sym<cond> {
        $<op>=[if|unless] ~ 'end' [ :s <xblock> [<else=.elsif>|<else>]? ]
    }

    token elsif {
        'elsif' ~ [<else=.elsif>|<else>]? <xblock>
    }

    token else {
         'else' <stmtlist>
    }

    token stmt:sym<loop> {
        $<op>=[while|until] :s <EXPR> :s <do-block>
    }

    token stmt:sym<for> {
        <sym> :s <ident> :s 'in' <EXPR> <do-block>
    }

    token do-block { <do> ~ 'end' <stmtlist> }

    token do { <separator> [:s 'do']? | 'do' | <?before <tmpl-unesc>>
    }

    token term:sym<code> {
        'begin' ~ 'end' <stmtlist> 
    }

    token term:sym<lambda> {
        'lambda' :s ['{' ['|' ~ '|' <signature>]? ]  ~ '}' <stmtlist> 
    }

    method builtin-init() {
        nqp::hash(
            'abort',  'die',
            'exit',   'exit',
            'print',  'print',
            'puts',   'say',
            'sleep',  'sleep',
            );
    }

    method sym-init() {
        my %builtins := self.builtin-init();
        my %sym;
        %sym{$_} := 'def' for %builtins;
        return %sym;
    }

    method hcopy(%in) {
        my %out;
        %out{$_} := %in{$_} for %in;
        return %out;
    }
}

class Rubyish::Actions is HLL::Actions {

    method TOP($/) {
        $*CUR_BLOCK.push($<stmtlist>.ast);
        make $*CUR_BLOCK;
    }

    method stmtlist($/) {
        my $stmts := QAST::Stmts.new( :node($/) );

        if $<stmt> {
            $stmts.push($_.ast)
                for $<stmt>;
        }

        make $stmts;
    }

    method template-chunk($/) {
        my $text := QAST::Stmts.new( :node($/) );
        $text.push( QAST::Op.new( :op<print>, $_.ast ) )
            for $<template-nibble>;
        
        make $text;
    }

    method template-nibble:sym<interp>($/) {
        make $<interp>.ast
    }

    method template-nibble:sym<plain-text>($/) {
        make QAST::SVal.new( :value(~$/) );
    }

    method stmtish($/) {
        make $<modifier>
            ?? QAST::Op.new( $<EXPR>.ast, $<stmt>.ast,
                             :op(~$<modifier>), :node($/) )
            !! $<stmt>.ast;
    }

    method term:sym<value>($/) { make $<value>.ast; }

    # a few ops that map directly to Ruby built-ins
    my %builtins;

    method term:sym<call>($/) {
        my $name  := ~$<operation>;
        %builtins := Rubyish::Grammar.builtin-init()
            unless %builtins<puts>;
        my $op    := %builtins{$name};

        my $call := $op
            ?? QAST::Op.new( :op($op) )
            !! QAST::Op.new( :op('call'), :name($name) );

        if $<call-args> {
            $call.push($_)
                for $<call-args>.ast;
        }

        make $call;
    }

    method term:sym<nqp-op>($/) {
        my $op := ~$<ident>;
        my $call := QAST::Op.new( :op($op) );

        if $<call-args> {
            $call.push($_)
                for $<call-args>.ast;
        }

        make $call;
    }

    method call-args($/) {
        my @args;
        @args.push($_.ast) for $<EXPR>;
        make @args;
    }

    method paren-args($/) {
        make $<call-args>.ast;
    }

    my $tmpsym := 0;

    method term:sym<new>($/) {

        # seems a bit hacky
        my $tmp-sym := '$new' ~ (++$tmpsym) ~ '$';

        my $init-call := QAST::Op.new( :op<callmethod>,
                                       :name<initialize>,
                                       QAST::Var.new( :name($tmp-sym), :scope<lexical> )
            );

        if $<call-args> {
            $init-call.push($_)
                for $<call-args>.ast;
        }

        make QAST::Stmt.new(

            # create the new object
            QAST::Op.new( :op('bind'),
                          QAST::Var.new( :name($tmp-sym), :scope<lexical>, :decl<var>),
                          QAST::Op.new(
                              :op('create'),
                              QAST::Var.new( :name('::' ~ ~$<ident>), :scope('lexical') )
                          ),
            ),

            # call initialize method, if available
            QAST::Op.new( :op<if>,
                          QAST::Op.new( :op<can>,
                                        QAST::Var.new( :name($tmp-sym), :scope<lexical> ),
                                        QAST::SVal.new( :value<initialize> )),
                          $init-call,
            ),

            # return the new object
            QAST::Var.new( :name($tmp-sym), :scope<lexical> ),
            );
    }

    method var($/) {
        my $sigil := ~$<sigil> // '';
        my $name := $sigil ~ $<ident>;
        my $block;
        my $decl := 'var';

        if $sigil eq '@' && $*IN_CLASS {
            # instance variable, bound to self
            make QAST::Var.new( :scope('attribute'),
                                QAST::Var.new( :name('self'), :scope('lexical')),
                                QAST::SVal.new( :value($name) )
                );
        }
        else {
            if $*MAYBE_DECL {

                if !$sigil {
                    $block := $*CUR_BLOCK;
                }
                elsif $sigil eq '$' {
                    $block := $*TOP_BLOCK;
                }
                elsif $sigil eq '@' {
                    $block := $*CLASS_BLOCK;
                }
                elsif $sigil eq '@@' {
                    $block := $*CLASS_BLOCK;
                    $decl  := 'static';                 
                }
                else {
                    nqp::die("unhandled sigil: $sigil");
                }

                my %sym  := $block.symbol($name);
                if !%sym<declared> {
                    %*SYM{$name} := 'var';
                    $block.symbol($name, :declared(1), :scope('lexical') );
                    my $var := QAST::Var.new( :name($name), :scope('lexical'),
                                              :decl($decl) );
                    $block[0].push($var);
                }
            }

            make QAST::Var.new( :name($name), :scope('lexical') );
        }
    }

    method term:sym<var>($/) { make $<var>.ast }

    method stmt:sym<def>($/) {
        my $install := $<defbody>.ast;
        $*CUR_BLOCK[0].push(QAST::Op.new(
            :op('bind'),
            QAST::Var.new( :name($install.name), :scope('lexical'), :decl('var') ),
            $install
        ));
        %*SYM{$install.name} := 'def';
        if $*IN_CLASS {
            @*METHODS.push($install);
        }
        make QAST::Op.new( :op('null') );
    }

    method defbody($/) {
        $*CUR_BLOCK.name(~$<operation>);
        if $<signature> {
            for $<signature>.ast {
                $*CUR_BLOCK[0].push($_);
                $*CUR_BLOCK.symbol($_.name, :declared(1));
            }
        }
        $*CUR_BLOCK.push($<stmtlist>.ast);
        if $*IN_CLASS {
            # it's a method, self will be automatically passed
            $*CUR_BLOCK[0].unshift(QAST::Var.new(
                :name('self'), :scope('lexical'), :decl('param')
            ));
            $*CUR_BLOCK.symbol('self', :declared(1));
        }
 
        make $*CUR_BLOCK;
    }

    method signature($/) {
        my @params;
        for $<param> {
              @params.push(QAST::Var.new(
                :name(~$_), :scope('lexical'), :decl('param')
            ));
        }
        make @params;
    }

    method stmt:sym<class>($/) {
        my $body_block := $<classbody>.ast;

        # Generate code to create the class.
        my $class_stmts := QAST::Stmts.new( $body_block );
        my $ins_name    := '::' ~ $<classbody><ident>;
        $class_stmts.push(QAST::Op.new(
            :op('bind'),
            QAST::Var.new( :name($ins_name), :scope('lexical'), :decl('var') ),
            QAST::Op.new(
                :op('callmethod'), :name('new_type'),
                QAST::WVal.new( :value(RubyishClassHOW) ),
                QAST::SVal.new( :value(~$<classbody><ident>), :named('name') ) )
            ));

        # Add methods.
        my $class_var := QAST::Var.new( :name($ins_name), :scope('lexical') );

        for @*METHODS {
            $class_stmts.push(QAST::Op.new(
                :op('callmethod'), :name('add_method'),
                QAST::Op.new( :op('how'), $class_var ),
                $class_var,
                QAST::SVal.new( :value($_.name) ),
                QAST::BVal.new( :value($_) )));
        }

        make $class_stmts;
    }
    method classbody($/) {
        $*CUR_BLOCK.push($<stmtlist>.ast);
        $*CUR_BLOCK.blocktype('immediate');
        make $*CUR_BLOCK;
    }

    method stmt:sym<EXPR>($/) { make $<EXPR>.ast; }

    method term:sym<assign>($/) { 
        my $op := $<OPER><O><op>;
        make  QAST::Op.new( :op('bind'),
                            $<var>.ast,
                            QAST::Op.new( :op($op),
                                          $<var>.ast,
                                          $<EXPR>.ast
                            ));
    }

    method value:sym<string>($/) {
        make $<strings>.ast;
    }

    method strings($/) {
        make $<strings>
            ?? QAST::Op.new( :op('concat'), $<string>.ast, $<strings>.ast)
            !! $<string>.ast;
    }

    method string($/) {
        make $<quote_EXPR>.ast;
    }

    method value:sym<integer>($/) {
        make QAST::IVal.new( :value(+$/.Str) )
    }

    method value:sym<float>($/) {
        make QAST::NVal.new( :value(+$/.Str) )
    }

    method paren-list($/) {
        my @list;
        if $<EXPR> {
            @list.push($_.ast) for $<EXPR>
        }
        make @list;
    }

    method value:sym<array>($/) {
        my $array := QAST::Op.new( :op<list> );
        $array.push($_) for $<paren-list>.ast;
        make $array;
    }

    method term:sym<quote-words>($/) {
        make $<quote_EXPR>.ast;
    }

    method value:sym<hash>($/) {
        my $hash := QAST::Op.new( :op<hash> );
        $hash.push($_) for $<paren-list>.ast;
        make $hash;
    }

    method value:sym<nil>($/) {
        make QAST::Op.new( :op<null> );
    }

    method value:sym<true>($/) {
        make QAST::IVal.new( :value<1> );
    }

    method value:sym<false>($/) {
        make QAST::IVal.new( :value<0> );
    }

    method interp($/) { make $<stmt>.ast }
    method quote_escape:sym<#{ }>($/) { make $<interp>.ast }
    method circumfix:sym<( )>($/) { make $<EXPR>.ast }

    # todo: proper type objects
    my %call-tab;
    sub call-tab-init() {
	%call-tab := nqp::hash(
	    'call', 'call',
	    'nil?', 'isnull'
	)
    }

    method postfix:sym<.>($/) {
	call-tab-init() unless %call-tab<call>;
	my $op := %call-tab{ ~$<operation> };
        my $meth_call := $op
            ?? QAST::Op.new( :op($op) )
            !! QAST::Op.new( :op('callmethod'), :name(~$<operation>) );

        if $<call-args> {
            $meth_call.push($_) for $<call-args>.ast;
        }

        make $meth_call;
    }

    method postcircumfix:sym<[ ]>($/) {
        make QAST::Var.new( :scope('positional'), $<EXPR>.ast );
    }

    method postcircumfix:sym<{ }>($/) {
        make QAST::Var.new( :scope('associative'), $<EXPR>.ast );
    }

    method postcircumfix:sym<ang>($/) {
        make QAST::Var.new( :scope('associative'), $<quote_EXPR>.ast );
    }

    method xblock($/) {
        make QAST::Op.new( $<EXPR>.ast, $<stmtlist>.ast, :node($/) );
    }

    method stmt:sym<cond>($/) {
        my $ast := $<xblock>.ast;
	$ast.op( ~$<op> );
        $ast.push( $<else>.ast )
            if $<else>;
 
        make $ast;
    }

    method elsif($/) {
        my $ast := $<xblock>.ast;
	$ast.op( 'if' );
        $ast.push( $<else>.ast )
            if $<else>;

        make $ast;
    }

    method else($/) {
        make $<stmtlist>.ast
    }

    method stmt:sym<loop>($/) {
        make QAST::Op.new( $<EXPR>.ast, $<do-block>.ast, :op(~$<op>), :node($/) );
    }

    method stmt:sym<for>($/) {

        my $block := QAST::Block.new(
            QAST::Var.new( :name(~$<ident>), :scope('lexical'), :decl('param')),
            $<do-block>.ast,
	    );

        make QAST::Op.new( $<EXPR>.ast, $block, :op('for'), :node($/) );
    }

    method do-block($/) {
	make  $<stmtlist>.ast
    }

    method term:sym<code>($/) {
        make $<stmtlist>.ast;
    }

    method term:sym<lambda>($/) {
        my $block := QAST::Block.new();
        if $<signature> {
            for $<signature>.ast {
                $block.push($_);
                $block.symbol($_.name, :declared(1));
            }
        }
        $block.push($<stmtlist>.ast);

        make  QAST::Op.new(:op<takeclosure>, $block );
    }

}

class Rubyish::Compiler is HLL::Compiler {
}

sub MAIN(*@ARGS) {
    my $comp := Rubyish::Compiler.new();
    $comp.language('rubyish');
    $comp.parsegrammar(Rubyish::Grammar);
    $comp.parseactions(Rubyish::Actions);
    $comp.command_line(@ARGS, :encoding('utf8'));
}
