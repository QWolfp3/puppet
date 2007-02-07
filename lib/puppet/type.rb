require 'puppet'
require 'puppet/log'
require 'puppet/element'
require 'puppet/event'
require 'puppet/metric'
require 'puppet/type/property'
require 'puppet/parameter'
require 'puppet/util'
require 'puppet/autoload'
require 'puppet/metatype/manager'

# see the bottom of the file for the rest of the inclusions

module Puppet
class Type < Puppet::Element
    # Nearly all of the code in this class is stored in files in the
    # metatype/ directory.  This is a temporary measure until I get a chance
    # to refactor this class entirely.  There's still more simplification to
    # do, but this works for now.
    require 'puppet/metatype/attributes'
    require 'puppet/metatype/closure'
    require 'puppet/metatype/container'
    require 'puppet/metatype/evaluation'
    require 'puppet/metatype/instances'
    require 'puppet/metatype/metaparams'
    require 'puppet/metatype/providers'
    require 'puppet/metatype/relationships'
    require 'puppet/metatype/schedules'
    require 'puppet/metatype/tags'

    # Types (which map to elements in the languages) are entirely composed of
    # attribute value pairs.  Generally, Puppet calls any of these things an
    # 'attribute', but these attributes always take one of three specific
    # forms:  parameters, metaparams, or properties.

    # In naming methods, I have tried to consistently name the method so
    # that it is clear whether it operates on all attributes (thus has 'attr' in
    # the method name, or whether it operates on a specific type of attributes.
    attr_accessor :file, :line
    attr_reader :parent

    attr_writer :title

    include Enumerable
    
    # class methods dealing with Type management

    public

    # the Type class attribute accessors
    class << self
        attr_reader :name
        attr_accessor :self_refresh
        include Enumerable, Puppet::Util::ClassGen
        include Puppet::MetaType::Manager
    end

    # all of the variables that must be initialized for each subclass
    def self.initvars
        # all of the instances of this class
        @objects = Hash.new
        @aliases = Hash.new

        @providers = Hash.new
        @defaults = {}

        unless defined? @parameters
            @parameters = []
        end

        @validproperties = {}
        @properties = []
        @parameters = []
        @paramhash = {}

        @paramdoc = Hash.new { |hash,key|
          if key.is_a?(String)
            key = key.intern
          end
          if hash.include?(key)
            hash[key]
          else
            "Param Documentation for %s not found" % key
          end
        }

        unless defined? @doc
            @doc = ""
        end

    end

    def self.to_s
        if defined? @name
            "Puppet::Type::" + @name.to_s.capitalize
        else
            super
        end
    end

    # Create a block to validate that our object is set up entirely.  This will
    # be run before the object is operated on.
    def self.validate(&block)
        define_method(:validate, &block)
        #@validate = block
    end

    # iterate across all children, and then iterate across properties
    # we do children first so we're sure that all dependent objects
    # are checked first
    # we ignore parameters here, because they only modify how work gets
    # done, they don't ever actually result in work specifically
    def each
        # we want to return the properties in the order that each type
        # specifies it, because it may (as in the case of File#create)
        # be important
        if self.class.depthfirst?
            @children.each { |child|
                yield child
            }
        end
        self.eachproperty { |property|
            yield property
        }
        unless self.class.depthfirst?
            @children.each { |child|
                yield child
            }
        end
    end

    # Recurse deeply through the tree, but only yield types, not properties.
    def delve(&block)
        self.each do |obj|
            if obj.is_a? Puppet::Type
                obj.delve(&block)
            end
        end
        block.call(self)
    end
    
    # create a log at specified level
    def log(msg)
        Puppet::Log.create(
            :level => @parameters[:loglevel].value,
            :message => msg,
            :source => self
        )
    end


    # instance methods related to instance intrinsics
    # e.g., initialize() and name()

    public

    def initvars
        @children = []
        @evalcount = 0
        @tags = []

        # callbacks are per object and event
        @callbacks = Hash.new { |chash, key|
            chash[key] = {}
        }

        # properties and parameters are treated equivalently from the outside:
        # as name-value pairs (using [] and []=)
        # internally, however, parameters are merely a hash, while properties
        # point to Property objects
        # further, the lists of valid properties and parameters are defined
        # at the class level
        unless defined? @parameters
            @parameters = {}
        end

        # set defalts
        @noop = false
        # keeping stats for the total number of changes, and how many were
        # completely sync'ed
        # this isn't really sufficient either, because it adds lots of special
        # cases such as failed changes
        # it also doesn't distinguish between changes from the current transaction
        # vs. changes over the process lifetime
        @totalchanges = 0
        @syncedchanges = 0
        @failedchanges = 0

        @inited = true
    end

    # initialize the type instance
    def initialize(hash)
        unless defined? @inited
            self.initvars
        end
        namevar = self.class.namevar

        orighash = hash

        # If we got passed a transportable object, we just pull a bunch of info
        # directly from it.  This is the main object instantiation mechanism.
        if hash.is_a?(Puppet::TransObject)
            #self[:name] = hash[:name]
            [:file, :line, :tags].each { |getter|
                if hash.respond_to?(getter)
                    setter = getter.to_s + "="
                    if val = hash.send(getter)
                        self.send(setter, val)
                    end
                end
            }

            # XXX This will need to change when transobjects change to titles.
            @title = hash.name
            hash = hash.to_hash
        elsif hash[:title]
            # XXX This should never happen
            @title = hash[:title]
            hash.delete(:title)
        end

        # Before anything else, set our parent if it was included
        if hash.include?(:parent)
            @parent = hash[:parent]
            hash.delete(:parent)
        end

        # Munge up the namevar stuff so we only have one value.
        hash = self.argclean(hash)

        # Let's do the name first, because some things need to happen once
        # we have the name but before anything else

        attrs = self.class.allattrs

        if hash.include?(namevar)
            #self.send(namevar.to_s + "=", hash[namevar])
            self[namevar] = hash[namevar]
            hash.delete(namevar)
            if attrs.include?(namevar)
                attrs.delete(namevar)
            else
                self.devfail "My namevar isn\'t a valid attribute...?"
            end
        else
            self.devfail "I was not passed a namevar"
        end

        # If the name and title differ, set up an alias
        if self.name != self.title
            if obj = self.class[self.name] 
                if self.class.isomorphic?
                    raise Puppet::Error, "%s already exists with name %s" %
                        [obj.title, self.name]
                end
            else
                self.class.alias(self.name, self)
            end
        end

        # This is all of our attributes except the namevar.
        attrs.each { |attr|
            if hash.include?(attr)
                begin
                    self[attr] = hash[attr]
                rescue ArgumentError, Puppet::Error, TypeError
                    raise
                rescue => detail
                    self.devfail(
                        "Could not set %s on %s: %s" %
                            [attr, self.class.name, detail]
                    )
                end
                hash.delete attr
            end
        }
        
        # Set all default values.
        self.setdefaults

        if hash.length > 0
            self.debug hash.inspect
            self.fail("Class %s does not accept argument(s) %s" %
                [self.class.name, hash.keys.join(" ")])
        end

        if self.respond_to?(:validate)
            self.validate
        end
    end

    # Set up all of our autorequires.
    def finish
        # Scheduling has to be done when the whole config is instantiated, so
        # that file order doesn't matter in finding them.
        self.schedule
    end

    # Return a cached value
    def cached(name)
        Puppet::Storage.cache(self)[name]
        #@cache[name] ||= nil
    end

    # Cache a value
    def cache(name, value)
        Puppet::Storage.cache(self)[name] = value
        #@cache[name] = value
    end

#    def set(name, value)
#        send(name.to_s + "=", value)
#    end
#
#    def get(name)
#        send(name)
#    end

    # For now, leave the 'name' method functioning like it used to.  Once 'title'
    # works everywhere, I'll switch it.
    def name
        return self[:name]
    end

    # Return the "type[name]" style reference.
    def ref
        "%s[%s]" % [self.class.name.to_s.capitalize, self.title]
    end
    
    def self_refresh?
        self.class.self_refresh
    end

    # Retrieve the title of an object.  If no title was set separately,
    # then use the object's name.
    def title
        unless defined? @title and @title
            namevar = self.class.namevar
            if self.class.validparameter?(namevar)
                @title = self[:name]
            elsif self.class.validproperty?(namevar)
                @title = self.should(namevar)
            else
                self.devfail "Could not find namevar %s for %s" %
                    [namevar, self.class.name]
            end
        end

        return @title
    end

    # convert to a string
    def to_s
        self.ref
    end

    # Convert to a transportable object
    def to_trans(ret = true)
        # Retrieve the object, if they tell use to.
        if ret
            retrieve()
        end

        trans = TransObject.new(self.title, self.class.name)

        properties().each do |property|
            trans[property.name] = property.is
        end

        @parameters.each do |name, param|
            # Avoid adding each instance name as both the name and the namevar
            next if param.class.isnamevar? and param.value == self.title
            trans[name] = param.value
        end

        trans.tags = self.tags

        # FIXME I'm currently ignoring 'parent' and 'path'

        return trans
    end

end # Puppet::Type
end

require 'puppet/propertychange'
require 'puppet/provider'
require 'puppet/type/component'
require 'puppet/type/pfile'
require 'puppet/type/pfilebucket'
require 'puppet/type/tidy'



# $Id$
