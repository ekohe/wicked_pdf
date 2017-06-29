# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'wicked_pdf/version'
require 'English'

Gem::Specification.new do |spec|
  spec.name          = 'wicked_pdf'
  spec.version       = WickedPdf::VERSION
  spec.authors       = ['Miles Z. Sterrett']
  spec.email         = 'miles.sterrett@gmail.com'
  spec.summary       = 'PDF generator (from HTML) gem for Ruby on Rails'
  spec.homepage      = 'https://github.com/mileszs/wicked_pdf'
  spec.license       = 'MIT'
  spec.date          = Time.now.strftime('%Y-%m-%d')
  spec.description   = <<desc
This version of Wicked PDF uses Chrome to print as PDF file.
desc

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_dependency 'activesupport'
  spec.add_dependency 'webkit_remote'
  spec.add_dependency 'pdf-reader'

  spec.add_development_dependency 'rails'
  spec.add_development_dependency 'bundler', '~> 1.3'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rubocop' if RUBY_VERSION >= '2.0.0'
  spec.add_development_dependency 'sqlite3'
  spec.add_development_dependency 'mocha'
  spec.add_development_dependency 'test-unit'
end
