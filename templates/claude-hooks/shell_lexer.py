"""Shell tokeniser for guard-bash: real quoting, $'..' decoding, operators, heredocs, $(...) and backticks."""
import os
import re

OPS = ('&>>', '<<<', '<<-', '&&', '||', ';;', '|&', '>>', '>|', '&>', '>&', '<<', '<&', '<>', ';', '|', '&', '(', ')', '>', '<', '\n')
REDIRS = {'&>>', '<<<', '<<-', '>>', '>|', '&>', '>&', '<<', '<&', '<>', '>', '<'}
HOME = os.path.expanduser('~')
ANSI = {'n': '\n', 't': '\t', 'r': '\r', 'a': '\a', 'b': '\b', 'e': '\x1b', 'E': '\x1b', 'f': '\f', 'v': '\v', '\\': '\\', "'": "'", '"': '"', '?': '?'}
VAR = re.compile(r'\$(\{[^}]*\}?|[A-Za-z_]\w*|[0-9@*#?$!-])')


class Word(str):
    """A word after quote removal. quoted: it held a quote; dynamic: it holds a $var, $(...) or `...`."""
    quoted = False
    dynamic = False


class Lexer:
    """Splits a script into segments {words, redirs, heredoc}; $(...) and `...` bodies go to .subs.
    .error names the first unterminated quote, substitution or trailing backslash."""
    def __init__(self, s):
        self.s, self.i, self.subs, self.pending, self.error = s, 0, [], [], None
        if re.search(r'(?<!\\)(\\\\)*\\\s*\Z', s):
            self.error = 'the command ends in a line continuation'

    def op(self):
        return next((o for o in OPS if self.s.startswith(o, self.i)), None)

    def parse(self, in_sub=False):
        segs, seg, s = [], {'words': [], 'redirs': [], 'heredoc': ''}, self.s
        closed = not in_sub
        while self.i < len(s):
            c, o = s[self.i], self.op()
            if c in ' \t' or s.startswith('\\\n', self.i):
                self.i += 1 if c in ' \t' else 2
            elif c == '#' and (self.i == 0 or s[self.i - 1] in ' \t\n;&|('):
                self.i = s.find('\n', self.i) if '\n' in s[self.i:] else len(s)
            elif o == ')' and in_sub:
                self.i += 1
                closed = True
                break
            elif o in REDIRS:
                self.i += len(o)
                while self.i < len(s) and s[self.i] in ' \t':
                    self.i += 1
                target = self.word()
                seg['redirs'].append((o, target))
                if o in ('<<', '<<-'):
                    self.pending.append((target, o, seg))
            elif o:
                self.i += len(o)
                if o == '\n':
                    self.heredocs()
                segs.append(seg)
                seg = {'words': [], 'redirs': [], 'heredoc': ''}
            else:
                w = self.word()
                if not (w.isdigit() and s[self.i:self.i + 1] in ('<', '>')):
                    seg['words'].append(w)
        if not closed:
            self.fail('$( has no closing )')
        return [x for x in segs + [seg] if x['words'] or x['redirs']]

    def fail(self, why):
        self.error = self.error or why

    def heredocs(self):
        for delim, o, seg in self.pending:
            while self.i < len(self.s):
                end = self.s.find('\n', self.i)
                end = len(self.s) if end < 0 else end
                line, self.i = self.s[self.i:end], end + 1
                if (line.lstrip('\t') if o == '<<-' else line) == delim:
                    break
                seg['heredoc'] += line + '\n'
        self.pending = []

    def word(self):
        s, out, meta = self.s, [], {'quoted': False, 'dynamic': False}
        if s.startswith('~', self.i) and (self.i + 1 == len(s) or s[self.i + 1] in '/ \t;&|)\n'):
            out.append(HOME)
            self.i += 1
        while self.i < len(s) and s[self.i] not in ' \t' and (self.op() is None or s.startswith('$(', self.i)):
            c = s[self.i]
            if c == '\\':
                out.append(s[self.i + 1:self.i + 2])
                self.i += 2
            elif s.startswith("$'", self.i):
                meta['quoted'] = True
                self.i += 2
                out.append(self.ansi_c())
            elif c == "'":
                meta['quoted'] = True
                j = s.find("'", self.i + 1)
                if j < 0:
                    self.fail('a single quote is not closed')
                    j = len(s)
                out.append(s[self.i + 1:j])
                self.i = j + 1
            elif c == '"' or s.startswith('$"', self.i):
                meta['quoted'] = True
                self.i += 1 if c == '"' else 2
                while self.i < len(s) and s[self.i] != '"':
                    self.quoted_char(out, meta)
                if self.i >= len(s):
                    self.fail('a double quote is not closed')
                self.i += 1
            elif c == '$' or c == '`':
                self.dollar(out, meta)
            else:
                out.append(c)
                self.i += 1
        w = Word(''.join(out))
        w.quoted, w.dynamic = meta['quoted'], meta['dynamic']
        return w

    def ansi_c(self):
        s, out = self.s, []
        while self.i < len(s) and s[self.i] != "'":
            c = s[self.i]
            if c != '\\':
                out.append(c)
                self.i += 1
                continue
            m = re.compile(r'\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[0-7]{1,3}|c.|.)', re.S).match(s, self.i)
            e = m.group(1)
            if e[0] in 'xuU':
                out.append(chr(int(e[1:], 16)))
            elif e[0] in '01234567':
                out.append(chr(int(e, 8)))
            elif e[0] == 'c':
                out.append(chr(ord(e[1]) & 31))
            else:
                out.append(ANSI.get(e, '\\' + e))
            self.i = m.end()
        if self.i >= len(s):
            self.fail("a $' quote is not closed")
        self.i += 1
        return ''.join(out)

    def dollar(self, out, meta):
        """$HOME expands; any other $var, $(...) or `...` marks the word dynamic and keeps its text."""
        s = self.s
        if s[self.i] == '`' or s.startswith('$(', self.i):
            meta['dynamic'] = True
            start = self.i
            self.substitution()
            out.append(s[start:self.i])
            return
        m = VAR.match(s, self.i)
        if not m:
            out.append('$')
            self.i += 1
            return
        if m.group(1) in ('HOME', '{HOME}'):
            out.append(HOME)
        else:
            meta['dynamic'] = True
            out.append(m.group(0))
        self.i = m.end()

    def quoted_char(self, out, meta):
        s, c = self.s, self.s[self.i]
        if c == '\\':
            nxt = s[self.i + 1:self.i + 2]
            out.append(nxt if nxt in '"\\$`\n' else c + nxt)
            self.i += 2
        elif c in '$`':
            self.dollar(out, meta)
        else:
            out.append(c)
            self.i += 1

    def substitution(self):
        s = self.s
        if s.startswith('$((', self.i):
            end = s.find('))', self.i)
            self.i = len(s) if end < 0 else end + 2
        elif s[self.i] == '$':
            self.i += 2
            self.subs.extend(self.parse(in_sub=True))
        else:
            end = s.find('`', self.i + 1)
            if end < 0:
                self.fail('a backtick is not closed')
                end = len(s)
            inner = Lexer(s[self.i + 1:end])
            self.subs.extend(inner.parse() + inner.subs)
            self.fail(inner.error) if inner.error else None
            self.i = end + 1
