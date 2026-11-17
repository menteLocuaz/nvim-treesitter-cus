
-- plugin/filetypes.lua

-- Wrapping the code in a `do ... end` block limits the scope of local variables.
-- This allows Lua's Garbage Collector to free the 'filetypes' table from memory
-- immediately after registering the languages, instead of keeping it alive
-- throughout the entire Neovim session.
do
  -- Safety check (optional, but recommended for public plugins).
  -- Protects users running Neovim versions older than 0.9.
  if not vim.treesitter.language.register then
    return
  end

  local filetypes = {
    angular = { 'htmlangular' },
    bash = { 'sh' },
    bibtex = { 'bib' },
    c_sharp = { 'cs', 'csharp' },
    commonlisp = { 'lisp' },
    cooklang = { 'cook' },
    devicetree = { 'dts' },
    diff = { 'gitdiff' },
    eex = { 'eelixir' },
    elixir = { 'ex' },
    embedded_template = { 'eruby' },
    erlang = { 'erl' },
    facility = { 'fsd' },
    faust = { 'dsp' },
    gdshader = { 'gdshaderinc' },
    git_config = { 'gitconfig' },
    git_rebase = { 'gitrebase' },
    glimmer = { 'handlebars', 'html.handlebars' },
    godot_resource = { 'gdresource' },
    haskell = { 'hs' },
    haskell_persistent = { 'haskellpersistent' },
    idris = { 'idris2' },
    ini = { 'confini', 'dosini' },
    janet_simple = { 'janet' },
    javascript = { 'javascriptreact', 'ecma', 'ecmascript', 'jsx', 'js' },
    json = { 'jsonc' },
    glimmer_javascript = { 'javascript.glimmer' },
    latex = { 'tex' },
    linkerscript = { 'ld' },
    m68k = { 'asm68k' },
    make = { 'automake' },
    markdown = { 'pandoc' },
    muttrc = { 'neomuttrc' },
    ocaml_interface = { 'ocamlinterface' },
    perl = { 'pl' },
    poe_filter = { 'poefilter' },
    powershell = { 'ps1' },
    properties = { 'jproperties' },
    python = { 'py', 'gyp' },
    qmljs = { 'qml' },
    runescript = { 'clientscript' },
    scala = { 'sbt' },
    slang = { 'shaderslang' },
    sqp = { 'mysqp' },
    ssh_config = { 'sshconfig' },
    starlark = { 'bzl' },
    surface = { 'sface' },
    systemverilog = { 'verilog' },
    t32 = { 'trace32' },
    tcl = { 'expect' },
    terraform = { 'terraform-vars' },
    textproto = { 'pbtxt' },
    tlaplus = { 'tla' },
    tsx = { 'typescriptreact', 'typescript.tsx' },
    typescript = { 'ts' },
    glimmer_typescript = { 'typescript.glimmer' },
    typst = { 'typ' },
    udev = { 'udevrules' },
    uxntal = { 'tal', 'uxn' },
    v = { 'vlang' },
    vhs = { 'tape' },
    xml = { 'xsd', 'xslt', 'svg' },
    xresources = { 'xdefaults' },
  }

  for lang, fts in pairs(filetypes) do
    vim.treesitter.language.register(lang, fts)
  end
end
