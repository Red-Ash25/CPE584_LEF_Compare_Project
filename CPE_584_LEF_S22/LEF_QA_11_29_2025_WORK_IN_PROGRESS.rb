#! /usr/bin/ruby -W0
#
# =FILE:   lef_QA.rb
#
# Fall 2020 revision control lives here: 
# https://github.com/Tannerpalin/LEFQA
#
# =AUTHORS: Tanner Palin, Michael Kamb, Mark Angulo
#
# Fall 2025 revision control lives here:
# 
#
# =AUTHOR:  Abrahim Hamdan, Ash Huang, Benjamin Perry
#
# =DESCRIPTION: 
#     Reads a LEF file and sorts the data numerically.
#     Checks pin direction between LEF and .lib file.
#     

require 'optparse'  # Used for parsing arguments 
require 'logger'    # Used for logging debug infomation at different levels
$log = Logger.new(STDOUT)
$log.level = Logger::INFO
$reportTime = Time.new # Timestamp for when this script is run.

# TODO: we are always passing file and index together, 
# wrap both in PBR_Int and then name it better (This is complete)
#
# Refactored: Replaces PBR_Int and global file reading functions.
# Handles navigating through the file lines and skipping empty space.
class LefParser
  attr_reader :index
  
  def initialize(file_lines)
    @lines = file_lines
    @index = 0
    parse_current_line()
  end
  
  # Returns the current line content
  def current
    return @current_text
  end
  
  # Advances to next line and returns it
  def next
    @index += 1
    parse_current_line()
    return @current_text
  end
  
  private
  def parse_current_line
    raw_line = @lines[@index]
    if !raw_line.nil?
      @current_text = raw_line.chomp()
    else
      @current_text = nil
    end
    
    # Skip empty lines automatically
    while (!@current_text.nil?) && @current_text.match(/\A\s*\Z/)
      @index += 1
      raw_line = @lines[@index]
      if !raw_line.nil?
        @current_text = raw_line.chomp()
      else
        @current_text = nil
      end
    end
  end
end

#
# parses tf file given by file_path. Stores a hash of valid layers with information.
# Handles Cadence Virtuoso TF format: techLayers( ... )
#
class TF_File
  attr_reader :layers, :layer_types
  
  def initialize(file_path)
      @layers = Array.new
      @layer_types = Hash.new  # Store layer types: { "VI1" => "CUT", "ME1" => "ROUTING" }
      @file_path = file_path
  end
  
  def tf_parse()
      # First pass: get layer names from techLayers section
      techLayers_found = false
      techLayers_end = false 
      paren_depth = 0
      
      File.foreach(@file_path).with_index do |line, line_num|
          # Check for start of techLayers section
          # Handle both formats: "techLayers(" and "(techLayers"
          if line.match(/techLayers\s*\(/) || line.match(/\(\s*techLayers/)
              techLayers_found = true
              paren_depth = 1
              next
          end
          
          next unless techLayers_found
          
          # Track parenthesis depth to find end of section
          open_parens = line.count('(')
          close_parens = line.count(')')
          
          # Skip comment lines (start with ;)
          if line.strip.match(/^;/)
              next
          end
          
          # Parse layer definition lines: ( LAYERNAME  NUMBER  ABBREV )
          if match = line.match(/^\s*\(\s*(\w+)\s+(\d+)\s+/)
              layer_name = match[1]
              @layers << layer_name unless layer_name.nil? || layer_name.empty?
          end
          
          # Track depth and check for section end
          paren_depth += open_parens - close_parens
          if paren_depth <= 0
              techLayers_end = true
              break
          end
      end
      
      # Second pass: parse layer types from various sections
      parse_layer_types()
  end
  
  # Parse layer types from the TF file
  # Look for validLayers section to identify VIA (CUT) and METAL (ROUTING) layers
  def parse_layer_types()
    # Read entire file to parse multi-line sections
    content = File.read(@file_path)
    
    # Find all validLayers sections and extract layer names
    # Pattern: ( validLayers ( ... ) )
    content.scan(/validLayers\s*\(\s*\(([\s\S]*?)\)\s*\)/m) do |match|
      layers_content = match[0]
      
      # Extract layer names - handles formats like:
      # (VIA1 drawing)
      # VIA1
      # "M1"
      layers_content.scan(/\(?\s*(\w+)\s+(?:drawing|pin|net)\s*\)?|\b(VIA\d+|M\d+|CO|CONT|AP)\b/i) do |grouped, standalone|
        layer_name = grouped || standalone
        next if layer_name.nil? || layer_name.empty?
        
        # Normalize to uppercase for storage
        layer_upper = layer_name.upcase
        
        # Classify based on name pattern
        if layer_upper =~ /^VIA\d*$/i || layer_upper =~ /^CO$/i || layer_upper =~ /^CONT$/i
          @layer_types[layer_upper] = "CUT"
          # Also store lowercase version for matching
          @layer_types[layer_name.downcase] = "CUT"
        elsif layer_upper =~ /^M\d+$/i || layer_upper =~ /^AP\d*$/i
          @layer_types[layer_upper] = "ROUTING"
          @layer_types[layer_name.downcase] = "ROUTING"
        end
      end
    end
    
    # Also check techLayers section for any layers with VIA/CO in the name
    @layers.each do |layer_name|
      layer_upper = layer_name.upcase
      if layer_upper =~ /^VIA\d*$/i || layer_upper =~ /^CO$/i || layer_upper =~ /^CONT$/i || layer_upper =~ /^MCON$/i
        @layer_types[layer_upper] = "CUT"
        @layer_types[layer_name] = "CUT"
        @layer_types[layer_name.downcase] = "CUT"
      elsif layer_upper =~ /^M\d+$/i || layer_upper =~ /^ME\d+$/i || layer_upper =~ /^AP\d*$/i
        @layer_types[layer_upper] ||= "ROUTING"
        @layer_types[layer_name] ||= "ROUTING"
        @layer_types[layer_name.downcase] ||= "ROUTING"
      end
    end
    
    # Debug output
    cut_layers = @layer_types.select { |k, v| v == "CUT" }.keys.uniq
    routing_layers = @layer_types.select { |k, v| v == "ROUTING" }.keys.uniq
    puts "  TF Parser found CUT layers: #{cut_layers.sort.join(', ')}" if !cut_layers.empty?
    puts "  TF Parser found ROUTING layers: #{routing_layers.sort.join(', ')}" if !routing_layers.empty?
  end
  
  # Check if a layer is a CUT layer (case-insensitive)
  def cut_layer?(layer_name)
    return false if layer_name.nil? || layer_name.empty?
    clean_name = layer_name.strip.gsub(/["']/, '').split()[0]
    # Check both original case and uppercase
    @layer_types[clean_name] == "CUT" || 
    @layer_types[clean_name.upcase] == "CUT" ||
    @layer_types[clean_name.downcase] == "CUT"
  end
  
  # Check if a layer is a ROUTING layer (case-insensitive)
  def routing_layer?(layer_name)
    return false if layer_name.nil? || layer_name.empty?
    clean_name = layer_name.strip.gsub(/["']/, '').split()[0]
    # Check both original case and uppercase
    @layer_types[clean_name] == "ROUTING" || 
    @layer_types[clean_name.upcase] == "ROUTING" ||
    @layer_types[clean_name.downcase] == "ROUTING"
  end
end

#
# parses tlef file given by file_path. Stores a hash of valid layers with information including TYPE.
#
class TLEF_File
  def initialize(file_path)
      @tlef_layers = Hash.new
      @file_path = file_path
  end

  def layers()
      return @tlef_layers.keys
  end
  
  # Returns hash of layer types: { "VI1" => "CUT", "ME1" => "ROUTING", ... }
  def layer_types()
    types = Hash.new
    @tlef_layers.each_pair do |layer_name, layer_info|
      types[layer_name] = layer_info['type'] if layer_info['type']
    end
    types
  end

  def _match_begin_layer(line)
      layer_name = ''
      if line.match(/^\s*LAYER\s+\w+\s*$/)
          layer_name = line.split(" ")[1]
          layer_name.rstrip!
      end
      return layer_name
  end

  def _match_end_layer(line)
      layer_name = ''
      if line.match(/^\s*END\s+\w+\s*$/)
          layer_name = line.split(" ")[1]
          layer_name.rstrip!
      end
      return layer_name
  end
  
  # Match TYPE line: "TYPE CUT ;" or "TYPE ROUTING ;"
  def _match_type(line)
    type_value = nil
    if match = line.match(/^\s*TYPE\s+(\w+)\s*;/)
      type_value = match[1].upcase
    end
    return type_value
  end

  def tlef_parse()
      current_layer = nil
      
      File.foreach(@file_path).with_index { |line, line_num|
          # Skip comments and empty lines
          if !(line.match(/^\s*\#/) or line.match(/^\s*$/))
              comment_split_line = line.split("#")
              line = comment_split_line[0]
              
              # Check for beginning of layer definition
              begin_layer = self._match_begin_layer(line)
              if begin_layer != ''
                  current_layer = begin_layer
                  @tlef_layers[begin_layer] = {
                    'begin_line' => line_num,
                    'type' => nil
                  }
              end 

              # Check for TYPE line (only if we're inside a layer definition)
              if current_layer
                layer_type = self._match_type(line)
                if layer_type
                  @tlef_layers[current_layer]['type'] = layer_type
                end
              end

              # Check for end of layer definition
              end_layer = self._match_end_layer(line)
              if end_layer != ''
                  if @tlef_layers.key?(end_layer)
                      @tlef_layers[end_layer]['end_line'] = line_num
                  end
                  current_layer = nil
              end
          end
      }
  end
  
  # Check if a layer is a CUT layer based on parsed TYPE
  def cut_layer?(layer_name)
    return false if layer_name.nil? || layer_name.empty?
    clean_name = layer_name.strip.split()[0]
    return false unless @tlef_layers.key?(clean_name)
    @tlef_layers[clean_name]['type'] == "CUT"
  end
  
  # Check if a layer is a ROUTING layer based on parsed TYPE
  def routing_layer?(layer_name)
    return false if layer_name.nil? || layer_name.empty?
    clean_name = layer_name.strip.split()[0]
    return false unless @tlef_layers.key?(clean_name)
    @tlef_layers[clean_name]['type'] == "ROUTING"
  end
end

class LEF_File
  attr_reader :cells
  def initialize(file_lines, errors)
    # Refactored: Use LefParser instead of Array + PBR_Int
    @parser = LefParser.new(file_lines)
    @errors = errors
    @header = Array.new
    @property_definitions = nil
    @cells = Hash.new
    
    # Use parser.current instead of get_current_line
    line = @parser.current
    until line.nil? || line.match(/PROPERTYDEFINITIONS/) || Cell::start_line?(line)
      if line.match(/\S;\s*$/)
        error_msg = (@parser.index + 1).to_s + "\n"
        @errors[:line_ending_semicolons].push(error_msg)
        line = line.gsub(/;\s*$/, " ;\n")
      end
      @header.push(line)
      # Use parser.next instead of get_next_line
      line = @parser.next
    end
    
    # Guard against nil line
    if line.nil?
      errors[:missing_end_library_token].push("")
      @end_line = nil
      return
    end
    
    if line.match(/PROPERTYDEFINITIONS/)
      @property_definitions = Array.new
      @property_definitions_start = line
      line = @parser.next
      until line.nil? || line.match(/END PROPERTYDEFINITIONS/)
        if line.match(/\S;\s*$/)
          error_msg = (@parser.index + 1).to_s + "\n"
          @errors[:line_ending_semicolons].push(error_msg)
          line = line.gsub(/;\s*$/, " ;\n")
        end
        @property_definitions.push(line)
        line = @parser.next
      end
      @property_definitions_end = line
      line = @parser.next
    else
      errors[:missing_property_definitions].push("")
    end
    
    end_of_file = false
    until end_of_file || line.nil? || line.match(/END LIBRARY/)
      if Cell::start_line?(line)
        # Pass the parser object instead of file + index
        new_cell = Cell.new(@parser, errors)
        @cells[new_cell.name] = new_cell
      else
        raise "Error: Unexpected line at #{@parser.index}: #{line}"
        @parser.next
      end
      line = @parser.current
      if line.nil?
        end_of_file = true
        errors[:missing_end_library_token].push("")
      end
    end
    
    # CHECK VIA OBS AFTER PARSING ALL CELLS
    @cells.each_value do |cell|
      cell.check_via_obs_association(errors)
    end
    
    @end_line = line
    
    # find properties that are strange, (TODO: should be deprecated) (COMPLETED: Deprecated and Removed)
    # check_for_uncommon_properties(@errors[:strange_class], Cell::classes_found)
    # check_for_uncommon_properties(@errors[:strange_symmetry], Cell::symmetries_found)
    # check_for_uncommon_properties(@errors[:strange_site], Cell::sites_found)
    # check_for_uncommon_properties(@errors[:strange_direction], Pin::directions_found)
    # check_for_uncommon_properties(@errors[:strange_use], Pin::uses_found)
  end
  def sort!()
    @cells.each_value{|cell| cell.sort!()}
  end
  
  # Refactored: Returns a string instead of printing directly
  def to_s
    output = ""
    @header.each do |line|
      output += line
    end
    
    if !(@property_definitions.nil?)
      output += @property_definitions_start
      @property_definitions.each do |line|
        output += line
      end
      output += @property_definitions_end
    end
    
    sortedCellKeys = @cells.keys.sort()
    sortedCellKeys.each do |key|
      # CALLING to_s HERE instead of print
      output += @cells[key].to_s
    end
    
    output += @end_line if @end_line
    return output
  end
  def [](ind)
    @cells[ind]
  end
end

class Cell
  attr_reader :pins, :properties, :keywordProperties, :name, :obstructions
  @@PropertyOrder = ["CLASS", "SOURCE", "FOREIGN", "ORIGIN", "EEQ", "SIZE", "SYMMETRY", "SITE", "DENSITY", "PROPERTY"]
  @@classes_found = Hash.new
  @@symmetries_found = Hash.new
  @@sites_found = Hash.new
  
  def self.start_line?(line)
    return false if line.nil?
    return line.match(/^MACRO\s+([\w\d_]+)/)
  end
  def self.register_property(target_hash, property_key, message)
    if target_hash[property_key].nil?
      target_hash[property_key] = Array.new
    end
    target_hash[property_key].push(message)
  end
  def self.classes_found
    return @@classes_found
  end
  def self.symmetries_found
    return @@symmetries_found
  end
  def self.sites_found
    return @@sites_found
  end

  # Refactored to use LefParser
  def initialize(parser, errors)
    class_found = false
    origin_found = false
    size_found = false
    symmetry_found = false
    site_found = false
    source_found = false
    
    line = parser.current
    if !Cell::start_line?(line)
      raise "Error: Attempted to initialize Cell, but file location provided did not start at a Cell."
    end
    @start_line = line
    @start_line_num = parser.index + 1
    @name = line.split()[1]
    @errors = errors

    $log.debug("Cell: " + @name)

    @properties = Array.new
    @keywordProperties = Array.new
    @pins = Hash.new
    @obstructions = nil
    
    line = parser.next
    while !line.nil? && !line.match(/^END/) && !Cell::start_line?(line)
      if Pin::start_line?(line)
        new_pin = Pin.new(parser, errors, @name)
        new_pin.parse() # Explicit parse call (Fixes TODO in Pin)
        @pins[new_pin.name] = new_pin
        #make all pin comparison uppercase
        @pins[new_pin.name.upcase] = new_pin
      elsif LayerCollection::start_line?(line)
        new_obstruction = LayerCollection.new(parser, errors)
        @obstructions = new_obstruction
      else
        if line.match(/\S;\s*$/)
          error_msg = (parser.index + 1).to_s + "\n"
          @errors[:line_ending_semicolons].push(error_msg)
          line = line.gsub(/;\s*$/, " ;\n")
        end
        split_line = line.split()
        split_line[0] = split_line[0].upcase()
        
        if split_line[0] == "PROPERTY"
          @keywordProperties.push(line)
        else
          @properties.push(line)
          
          # TODO: should be case split_line[0] (COMPLETED: Refactored to case statement below)
          case split_line[0]
          when "ORIGIN"
            origin_found = true
            if split_line[1] != "0" || split_line[2] != "0" then
              @errors[:strange_origin].push("Line " + (parser.index + 1).to_s + ": " + @name + "\n")
            end
          when "FOREIGN"
            if split_line[2] != "0" || split_line[3] != "0" then
              @errors[:strange_foreign].push("Line " + (parser.index + 1).to_s + ": " + @name + "\n")
            end
          when "CLASS"
            class_found = true
            Cell::register_property(@@classes_found, split_line[1], "Line " + (parser.index + 1).to_s() + ": " + @name + " - " + split_line[1] + "\n")
          when "SIZE"
            size_found = true
          when "SYMMETRY"
            symmetry_found = true
            Cell::register_property(@@symmetries_found, split_line[1], "Line " + (parser.index + 1).to_s() + ": " + @name + " - " + split_line[1] + "\n")
          when "SITE"
            site_found = true
            Cell::register_property(@@sites_found, split_line[1], "Line " + (parser.index + 1).to_s() + ": " + @name + " - " + split_line[1] + "\n")
          when "SOURCE"
            source_found = true
          else
            if !(@@PropertyOrder.include? line.split[0].upcase)
              error_msg = "Line " + (parser.index + 1).to_s + ": " + line.strip + "\n"
              @errors[:unknown_cell_property].push error_msg
            end
          end
        end
        parser.next
      end
      line = parser.current
    end
    
    $log.debug((parser.index + 1).to_s + ": END cell line " + line.to_s)

    if !origin_found
      @errors[:missing_origin].push("Line " + @start_line_num.to_s() + ": " + @name + "\n")
    end
    if !class_found
      @errors[:missing_class].push("Line " + @start_line_num.to_s() + ": " + @name + "\n")
    end
    if !symmetry_found
      @errors[:missing_symmetry].push("Line " + @start_line_num.to_s() + ": " + @name + "\n")
    end
    if !site_found
      @errors[:missing_site].push("Line " + @start_line_num.to_s() + ": " + @name + "\n")
    end
    if !size_found
      @errors[:missing_size].push("Line " + @start_line_num.to_s() + ": " + @name + "\n")
    end

    # TODO: If SOURCE is part of LEF syntax, then add this code to script, otherwise delete code (NOT DONE)
    # TODO: Also need to add "missing_source" key to errors array (NOT DONE)
    #if !source_found
    #  @errors[:missing_source].push("Line " + @start_line_num.to_s() + ": " + @name + "\n")
    #end

    # make sure you have end line
    if !line.nil? && line.match(/^END/)
      @end_line = line
      if !line.match(/^END #{Regexp.quote(@name)}/)
        @errors[:mangled_cell_end].push("Line " + (parser.index + 1).to_s() + ": " + @name + "\n")
      end
      parser.next
    else
      @errors[:missing_cell_end].push("Line " + (parser.index + 1).to_s() + ": " + @name + "\n")
    end
  end
  
  # Check if vias have associated OBS layers
  def check_via_obs_association(errors)
    # Collect all cut (via) layers from pins
    pin_cut_layers = collect_cut_layers_from_pins()
    
    # If no cut layers found, nothing to check
    return if pin_cut_layers.empty?
    
    # Check if cell has OBS section
    if @obstructions.nil?
      # Group by pin_name and cut_layer to consolidate errors
      grouped = {}
      pin_cut_layers.each do |cut_layer, pin_info_list|
        pin_info_list.each do |pin_info|
          key = "#{pin_info[:pin_name]}|#{cut_layer}"
          grouped[key] ||= { pin_name: pin_info[:pin_name], cut_layer: cut_layer, count: 0 }
          grouped[key][:count] += 1
        end
      end
      
      grouped.each_value do |info|
        count_str = info[:count] > 1 ? " (#{info[:count]} vias)" : ""
        errors[:missing_via_obs] << "Cell #{@name}, pin #{info[:pin_name]} - cut layer #{info[:cut_layer]} missing from OBS (no OBS section)#{count_str}\n"
      end
      return
    end
    
    # Get all OBS layer names (normalized for comparison)
    obs_layer_names = @obstructions.layers.keys.map { |name| normalize_layer_name(name) }
    
    # For each cut layer found in pins, check if it exists in OBS
    # Group by pin_name to consolidate errors
    missing_by_pin = {}
    
    pin_cut_layers.each do |cut_layer, pin_info_list|
      normalized_cut = normalize_layer_name(cut_layer)
      
      # Check if this cut layer exists in OBS
      unless obs_layer_names.include?(normalized_cut)
        pin_info_list.each do |pin_info|
          key = "#{pin_info[:pin_name]}|#{cut_layer}"
          missing_by_pin[key] ||= { pin_name: pin_info[:pin_name], cut_layer: cut_layer, count: 0 }
          missing_by_pin[key][:count] += 1
        end
      end
    end
    
    # Output one consolidated error per pin/layer combination
    missing_by_pin.each_value do |info|
      count_str = info[:count] > 1 ? " (#{info[:count]} vias)" : ""
      errors[:missing_via_obs] << "Cell #{@name}, pin #{info[:pin_name]} - cut layer #{info[:cut_layer]} missing from OBS#{count_str}\n"
    end
  end
  
  # Helper: Collect all cut/via layers from cell's pins
  def collect_cut_layers_from_pins()
    cut_layers = Hash.new { |h, k| h[k] = [] }
    
    @pins.each_pair do |pin_name, pin|
      pin.ports.each do |port|
        port.layers.each_pair do |layer_name, layer|
          clean_name = normalize_layer_name(layer_name)
          if LayerCollection.cut_layer?(clean_name)
            layer.coordinates.each_with_index do |coord, idx|
              line_num = layer.line_number_for_coordinate(idx) || @start_line_num
              cut_layers[clean_name] << {
                pin_name: pin_name,
                line_num: line_num,
                layer_name: clean_name
              }
            end
          end
        end
      end
    end
    
    cut_layers
  end
  
  # Helper: Normalize layer name for comparison
  def normalize_layer_name(name)
    return "" if name.nil?
    name.strip.split()[0].upcase
  end
  
  # TODO: probably should have to do a sort before this, so sort! should be private and called here (NOT DONE)
  def sort!()
    @pins.each_value{|pin| pin.sort!()}
    if(!@obstructions.nil?)
      @obstructions.sort!()
    end
    @properties.sort!{ |a, b|
      a_key = ""
      b_key = ""
      a.match(/\A\s*([\w\d_]+)/){ |m| a_key = m[1]}
      b.match(/\A\s*([\w\d_]+)/){ |m| b_key = m[1]}
      sort_by_property_list(@@PropertyOrder, a_key, b_key, a<=>b)
    }
    @keywordProperties.sort!()
  end
  
  # Refactored: Returns a string instead of printing directly
  # TODO: writing to a file all over the place is inadvisable, 
  # it would be better to ouput a string (COMPLETED: Converted to to_s method)
  def to_s
    output = ""
    output += @start_line
    
    @properties.each do |line|
      output += line
    end
    
    sortedPinKeys = @pins.keys.sort()
    sortedPinKeys.each do |key|
      output += @pins[key].to_s
    end
    
    if(!@obstructions.nil?)
      output += @obstructions.to_s
    end
    
    @keywordProperties.each do |line|
      output += line
    end

    output += @end_line
    output += "\n"
    
    return output
  end
  def [](ind)
    # associate pins to the index of the cells
    @pins[ind]
  end
end

class Pin
  attr_reader :properties, :keywordProperties, :name, :ports
  @@PropertyOrder = [
    "TAPERRULE", "DIRECTION", "USE", "NETEXPR", "SUPPLYSENSITIVITY", 
    "GROUNDSENSITIVITY", "SHAPE", "MUSTJOIN", "PROPERTY", 
    "ANTENNAPARTIALMETALAREA", "ANTENNAPARTIALMETALSIDEAREA", 
    "ANTENNAPARTIALCUTAREA", "ANTENNADIFFAREA", "ANTENNAMODEL", 
    "ANTENNAGATEAREA", "ANTENNAMAXAREACAR", "ANTENNAMAXSIDEAREACAR", 
    "ANTENNAMAXCUTCAR"
  ]
  @@directions_found = Hash.new
  @@uses_found = Hash.new
  def self.directions_found
    return @@directions_found
  end
  def self.uses_found
    return @@uses_found
  end
  def self.start_line?(line)
    return false if line.nil?
    return line.match(/^\s*PIN\s+/)
  end
  def self.register_property(target_hash, property_key, message)
    if target_hash[property_key].nil?
      target_hash[property_key] = Array.new
    end
    target_hash[property_key].push(message)
  end
  
  # TODO: initialize should not do any work, seperate into a function that gets called by user (COMPLETED: Logic moved to parse() method)
  def initialize(parser, errors, parent_cell_name)
    @parser = parser
    @errors = errors
    @parent_cell_name = parent_cell_name
    
    # Initialize containers
    @properties = Array.new
    @keywordProperties = Array.new
    @ports = Array.new
  end
  
  # New Method: Performs the actual work of parsing the Pin
  def parse()
    line = @parser.current
    if !Pin::start_line?(line)
      raise "Error: Attempted to initialize Pin, but file location provided did not start at a Pin."
    end
    found_direction = false
    found_use = false
    @start_line = line
    @start_line_num = @parser.index + 1
    
    raw_name = line.split(/PIN /)[1]
    @name = raw_name.chomp().strip.gsub(/;.*$/, '').strip
    
    $log.debug("Pin: " + @name)
      
    line = @parser.next
    while !line.nil? && !line.match(/^\s*END #{Regexp.quote(@name)}/)
      if LayerCollection::start_line?(line)
        new_port = LayerCollection.new(@parser, @errors)
        @ports.push(new_port)
      else
        $log.debug((@parser.index + 1).to_s + ": found pin property " + line)
        
        if line.match(/\S;\s*$/)
          error_msg = (@parser.index + 1).to_s + "\n"
          @errors[:line_ending_semicolons].push(error_msg)
          line = line.gsub(/;\s*$/, " ;\n")
        end

        if line.match(/^\s*PROPERTY/)
          @keywordProperties.push(line)
        else
          @properties.push(line)
          if !(@@PropertyOrder.include? line.split[0].upcase)
            error_msg = "Line " + (@parser.index + 1).to_s + ": " + line.strip + "\n"
            @errors[:unknown_pin_property].push error_msg
          end
          m = line.split()
          m[0] = m[0].upcase
          if m[0] == "DIRECTION"
            found_direction = true
            Pin::register_property(@@directions_found, m[1], "Line " + (@parser.index + 1).to_s() + ": Cell " + @parent_cell_name + ", pin " + @name + " - " + m[1] + "\n")
          end
          if m[0] == "USE"
            found_use = true
            Pin::register_property(@@uses_found, m[1], "Line " + (@parser.index + 1).to_s() + ": Cell " + @parent_cell_name + ", pin " + @name + " - " + m[1] + "\n")
          end
        end
        @parser.next
      end
      line = @parser.current
    end
    if !found_direction
      @errors[:missing_direction].push("Line " + @start_line_num.to_s() + ": Cell " + @parent_cell_name + ", pin " + @name + "\n")
    end
    if !found_use
      @errors[:missing_use].push("Line " + @start_line_num.to_s() + ": Cell " + @parent_cell_name + ", pin " + @name + "\n")
    end
    @end_line = line
    @parser.next
  end
  
  def sort!()
    @ports = @ports.sort{
      |a, b|
      a.compare_to(b)
    }
    @ports.each{|port| port.sort!()}
    @properties = @properties.sort{ |a, b|
      a_key = a.split()[0].upcase
      b_key = b.split()[0].upcase
      sort_by_property_list(@@PropertyOrder, a_key, b_key, a<=>b)
    }
    @keywordProperties.sort!()
  end
  
  # Refactored: Returns a string instead of printing directly
  def to_s
    output = ""
    output += @start_line
    
    @properties.each do |line|
      output += line
    end
    
    @ports.each do |port|
      output += port.to_s
    end
    
    @keywordProperties.each do |line|
      output += line
    end
    
    output += @end_line
    return output
  end
  def [](ind)
    return @layers[ind]
  end
end

class Layer
  attr_reader :name, :coordinates
  @@coordinate_pad_precision = 3
  
  def self.start_line?(line)
    return false if line.nil?
    return line.match(/^\s*LAYER/)
  end
  
  # Refactored to use LefParser
  def initialize(parser, errors)
    line = parser.current
    if !Layer::start_line?(line)
      raise "Error: Attempted to initialize Layer, but file location provided did not start at a Layer."
    end
    @errors = errors
    @start_line = line
    @start_line_num = parser.index + 1
    
    raw_name = line.split(/LAYER /)[1]
    @name = raw_name.strip.gsub(/;.*$/, '').strip
    
    if !LayerCollection::recognized_layer?(@name)
      @errors[:unknown_layer].push("Line " + (parser.index + 1).to_s() + ": " + line)
    end
    
    $log.debug((parser.index + 1).to_s + ": found layer " + line)
    
    if line.match(/\S;\s*$/)
      error_msg = (parser.index + 1).to_s + "\n"
      @errors[:line_ending_semicolons].push(error_msg)
      line = line.gsub(/;\s*$/, " ;\n")
    end

    @coordinates = Array.new
    @coordinate_line_numbers = Array.new
    
    line = parser.next
    
    $log.debug((parser.index + 1).to_s + ":" + line.to_s)
    
    until line.nil? || line.match(/(LAYER)|(END)/)
      if line.match(/\S;\s*$/)
        error_msg = (parser.index + 1).to_s + "\n"
        @errors[:line_ending_semicolons].push(error_msg)
        line = line.gsub(/;\s*$/, " ;\n")
      end
      
      current_line_num = parser.index + 1
      
      coordinate_pieces = line.split()
      line  = line.split(/\w/)[0]
      line += coordinate_pieces[0]
      for i in 1..4
        if coordinate_pieces[i] && !coordinate_pieces[i].match(/\.\d{#{@@coordinate_pad_precision + 1}}/)
          current_num = coordinate_pieces[i].to_f()
          line += " " + "%.#{@@coordinate_pad_precision}f" % current_num
        elsif coordinate_pieces[i]
          line += " " + coordinate_pieces[i]
        end
      end
      line += " ;\n"
      
      @coordinates.push(line)
      @coordinate_line_numbers.push(current_line_num)
      
      line = parser.next
      
      $log.debug((parser.index + 1).to_s + ":" + line.to_s)
    end
  end
  
  def line_number_for_coordinate(coord_index)
    return @start_line_num if @coordinate_line_numbers.nil? || @coordinate_line_numbers.empty?
    @coordinate_line_numbers[coord_index] || @start_line_num
  end
  
  def sort!()
    if @coordinate_line_numbers && @coordinate_line_numbers.length == @coordinates.length
      paired = @coordinates.zip(@coordinate_line_numbers)
      paired.sort! { |a, b| Layer::coordSort(a[0], b[0]) }
      @coordinates = paired.map { |p| p[0] }
      @coordinate_line_numbers = paired.map { |p| p[1] }
    else
      @coordinates = @coordinates.sort { |a, b| Layer::coordSort(a, b) }
    end
  end
  
  def self.coordSort(a, b) 
    aspl = a.split()
    bspl = b.split()
    result = 0
    if aspl[0] != bspl[0]
      result = aspl[0] <=> bspl[0]
    else
      aspl.zip(bspl).each do |aword, bword|
        af = aword.to_f()
        bf = bword.to_f()
        if af != bf
          result = af <=> bf
          break
        end
      end
    end
    return result
  end
  
  # Refactored: Returns a string instead of printing directly
  def to_s
    output = ""
    output += @start_line
    
    @coordinates.each do |line|
      output += line
    end
    
    return output
  end
  
  def compare_to(other_layer)
    if @coordinates.length() != other_layer.coordinates().length()
      return @coordinates.length() <=> other_layer.coordinates().length()
    else
      index = 0
      @coordinates.each do |coordinate|
        comparison = Layer::coordSort(coordinate, other_layer.coordinates()[index]) 
        if comparison != 0
          return comparison
        end
        index += 1
      end
    end
    return 0
  end
end

class LayerCollection

  @@layer_order_selected = "s40"
  @@layer_orders = Hash.new
  # TODO: make techfile or TLEF required for Layer checks, these lists 
  # (COMPLETED: TLEF/TF parsing now extracts layer types for CUT/ROUTING detection)
  @@layer_orders["s40"] = Array["LP_HVTP","LP_HVTN","CONT", "ME1", "VI1", "ME2","VI2","ME3"]
  @@layer_orders["abc"] = Array["met2", "via", "met1", "mcon", "li1", "nwell", "pwell"]
  
  # Store layer type information from TLEF/TF file
  @@layer_types = Hash.new
  
  # Fallback patterns - ONLY used if no TLEF is provided or layer not found in TLEF
  @@fallback_cut_patterns = [
    /^VI\d*$/i,
    /^VIA\d*$/i,
    /^V\d+$/i,
    /^CUT\d*$/i,
    /^CONT$/i,
    /^MCON$/i,
    /^CONTACT$/i,
    /^CO$/i
  ]
  
  @@fallback_routing_patterns = [
    /^ME\d+$/i,
    /^MET\d+$/i,
    /^METAL\d*$/i,
    /^M\d+$/i,
    /^LI\d*$/i,
    /^AP\d*$/i
  ]
  
  @@fallback_warning_shown = false

  attr_reader :layers
  
  def self.start_line?(line)
    return false if line.nil?
    return line.match(/^\s*(OBS)|(PORT)/)
  end
  
  # Set layer types from TLEF/TF parsing
  def self.set_layer_types(layer_types_hash)
    @@layer_types = layer_types_hash
    if !@@layer_types.empty?
      puts "Loaded #{@@layer_types.size} layer types from technology file"
      cut_count = @@layer_types.values.count("CUT")
      routing_count = @@layer_types.values.count("ROUTING")
      puts "  - CUT layers: #{cut_count}"
      puts "  - ROUTING layers: #{routing_count}"
    end
  end
  
  # Check if layer types have been loaded from TLEF
  def self.has_layer_types?
    !@@layer_types.empty?
  end
  
  # Check if a layer is a CUT layer
  def self.cut_layer?(layer_name)
    return false if layer_name.nil? || layer_name.empty?
    clean_name = layer_name.strip.split()[0]
    upper_name = clean_name.upcase
    lower_name = clean_name.downcase
    
    # If we have TLEF data, check it first
    if has_layer_types?
      # Check all case variants in TLEF data
      if @@layer_types[clean_name] == "CUT" ||
         @@layer_types[upper_name] == "CUT" ||
         @@layer_types[lower_name] == "CUT"
        return true
      end
      
      # If layer is explicitly defined as non-CUT in TLEF, return false
      if @@layer_types.key?(clean_name) || @@layer_types.key?(upper_name) || @@layer_types.key?(lower_name)
        return false
      end
      
      # Layer not found in TLEF - fall back to pattern matching with warning
      if !@@fallback_warning_shown
        $log.warn("Some layers not found in TLEF - using fallback pattern matching for unknown layers")
        @@fallback_warning_shown = true
      end
    else
      # No TLEF at all - use fallback patterns with warning
      if !@@fallback_warning_shown
        $log.warn("No TLEF layer types loaded - using fallback pattern matching for layer type detection")
        @@fallback_warning_shown = true
      end
    end
    
    # Fallback to pattern matching
    @@fallback_cut_patterns.any? { |pattern| upper_name =~ pattern }
  end
  
  # Check if a layer is a ROUTING layer
  def self.routing_layer?(layer_name)
    return false if layer_name.nil? || layer_name.empty?
    clean_name = layer_name.strip.split()[0]
    upper_name = clean_name.upcase
    lower_name = clean_name.downcase
    
    # If we have TLEF data, check it first
    if has_layer_types?
      # Check all case variants in TLEF data
      if @@layer_types[clean_name] == "ROUTING" ||
         @@layer_types[upper_name] == "ROUTING" ||
         @@layer_types[lower_name] == "ROUTING"
        return true
      end
      
      # If layer is explicitly defined as non-ROUTING in TLEF, return false
      if @@layer_types.key?(clean_name) || @@layer_types.key?(upper_name) || @@layer_types.key?(lower_name)
        return false
      end
      
      # Layer not found in TLEF - fall back to pattern matching
    end
    
    # Fallback to pattern matching
    @@fallback_routing_patterns.any? { |pattern| upper_name =~ pattern }
  end
  
  def self.layer_order=(new_order)
    if @@layer_orders[new_order].nil?
      puts "Warning: Layer order '#{new_order}' is not defined.\n"
      puts "Using order '#{@@layer_order_selected}' instead.\n"
    else
      @@layer_order_selected = new_order
    end
  end
  def self.layer_order()
    return @@layer_order_selected
  end

  def self.use_tlef_layers(new_layers)
    new_layer_order = "from_tlef"
    @@layer_orders[new_layer_order] = new_layers
    @@layer_order_selected = new_layer_order
  end

  def self.recognized_layer?(name)
    return @@layer_orders[@@layer_order_selected].include?(name.split()[0])
  end
  
  # Refactored to use LefParser
  def initialize(parser, errors)
    line = parser.current
    if !LayerCollection::start_line?(line)
      raise "Error: Attempted to initialize Obstruction or Port, but file location provided did not start at an Obstruction or Port."
    end
    @start_line = line
    @layers = Hash.new
    @errors = errors
    line = parser.next
    while(!line.nil? && Layer::start_line?(line))
      new_layer = Layer.new(parser, errors)
      @layers[new_layer.name] = new_layer
      line = parser.current
    end
    @end_line = line
    parser.next
  end
  
  def sort!()
    @layers.each_value{|layer| layer.sort!()}
  end
  
  # Refactored: Returns a string instead of printing directly
  def to_s
    output = ""
    output += @start_line
    sorted_layer_names = @layers.keys().sort{ |a, b| layer_name_sort(a, b) }
    sorted_layer_names.each do |key|
      output += @layers[key].to_s
    end
    
    # Print VIA statements (if any)
    if defined?(@vias) && @vias
        @vias.each do |via|
            output += via['line']
        end
    end
    
    output += @end_line
    return output
  end
  def [](ind)
    return @layers[ind]
  end
  def layer_name_sort(a, b)
    layer_order = @@layer_orders[@@layer_order_selected]
    a_key = a.split()[0]
    b_key = b.split()[0]
    return sort_by_property_list(layer_order, a_key, b_key, a<=>b)
  end
  def compare_to(other_collection)
    these_keys = @layers.keys().sort()
    those_keys = other_collection.layers().keys().sort()
    index = 0
    these_keys.each do |key|
      if those_keys[index].nil?
        return -1
      end
      if key != those_keys[index]
        return key <=> those_keys[index]
      end
      index += 1
    end
    if !those_keys[index].nil?
      return 1
    end
    these_keys.each do |key|
      comparison = @layers[key].compare_to(other_collection.layers()[key])
      if comparison != 0
        return comparison
      end
    end
    return 0
  end
end

def sort_by_property_list(list, a, b, tiebreaker)
  if list.include?(a) && list.include?(b)
    if list.index(a) != list.index(b)
      return list.index(a) <=> list.index(b)
    else
      return tiebreaker
    end
  elsif list.include?(a)
    return -1
  elsif list.include?(b)
    return 1
  else
    return tiebreaker
  end
  return 0
end

#
# find properties that are strange, (TODO: should be deprecated)
#
def check_for_uncommon_properties(error_array, property_hash)
  rarity_factor_cutoff = 5
  property_type_count = property_hash.keys().length()
  total_property_count = 0
  property_hash.keys().each do |key|
    total_property_count += property_hash[key].length()
  end
  property_hash.keys().each do |key|
    if property_hash[key].length() < (total_property_count / property_type_count) / rarity_factor_cutoff 
      property_hash[key].each do |line|
        error_array.push(line)
      end
    end
  end
end

# TODO: collect all of the "get_current_line" and file related methods 
# and store them under one function class or File wrapper object


# class for housing the different syntax rules and comparison checks against the liberty file
# TODO: collect preexisting rules and move them here, do the same for lef and tlef
class LibRuleChecker
  def self.check_pin_value_in_lef(lib_path, lef_path, lef_pin, lib_pin, lib_pin_prop_key, cell)
    errors = []
    lib_pin_name = lib_pin.name
    lib_pin_prop = lib_pin.property(lib_pin_prop_key)

    if lib_pin_prop.nil?
      errors << "#{cell}\n\tFiles: #{lib_path}, #{lef_path}, \n\tPin: #{lib_pin_name}, \n\tProperty: #{lib_pin_prop_key}, Property in LIB is NIL\n"
      return errors
    else 
      lib_pin_prop = lib_pin_prop.gsub(/[\";]/, '').strip.upcase
    end

    lef_prop_key = lib_pin_prop_key.upcase()
    lef_prop_name_re = /^\s*#{lef_prop_key}(.*)/
    lef_prop_val_re = /.*#{lib_pin_prop.gsub(/[\"\n;]/, '')}.*/
    lef_pin_prop_str = []

    lib_val = lib_pin.property(lib_pin_prop_key)
    lef_has_key = lef_pin.properties.any? { |p| p.strip.upcase.start_with?(lib_pin_prop_key.upcase) }

    # Skip if LIB does not define the property OR LEF does not define the property
    unless lib_val && lef_has_key
      return errors
    end

    if lib_pin_prop_key.upcase == "DIRECTION"
      puts "CELL=#{cell} PIN=#{lib_pin_name} — Checking DIRECTION"

      # Normalize Liberty direction
      lib_dir = lib_pin.property("direction")
      lib_dir = lib_dir.to_s.gsub(/[\";]/, "").strip.upcase
      # Find LEF direction lines
      lef_dir_lines = lef_pin.properties.select do |prop_str|
        prop_str.strip.upcase.start_with?("DIRECTION")
      end
      if lef_dir_lines.empty?
        return errors
      end
      # Extract LEF direction from the first token after "DIRECTION"
      lef_dir = lef_dir_lines.first.split[1].gsub(/[\";]/, "").strip.upcase
      # Compare exactly, no special cases
      unless lef_dir == lib_dir
        puts "  ERROR: Direction mismatch LIB=#{lib_dir}, LEF=#{lef_dir}"
        errors << "#{cell}\n\tPin #{lib_pin_name}: DIRECTION mismatch — LIB=#{lib_dir}, LEF=#{lef_dir}\n"
      end
##wrong logic 
=begin
    elsif lib_pin_prop_key.upcase == "PG_TYPE"
      puts "CELL=#{cell} PIN=#{lib_pin_name} — Checking PG_TYPE"

      # Normalize LIB value
      lib_pg_val = lib_pin.property("pg_type")
      lib_pg_val = lib_pg_val.to_s.gsub(/[\";]/, "").strip.upcase
      lib_pg_val = "" if lib_pg_val.nil? || lib_pg_val.empty?
      # Get LEF USE property lines
      lef_use_lines = lef_pin.properties.select do |prop_str|
        prop_str.strip.upcase.start_with?("USE")
      end
      if lef_use_lines.empty?
        errors << "#{cell}\n\tPin #{lib_pin_name}: Missing LEF USE property for PG_TYPE\n"
        return errors
      end
      lef_use_val = lef_use_lines.first.split[1].gsub(/[\";]/, "").strip.upcase
      # Cases:
      case lib_pg_val
      when "PRIMARY_POWER"
        # Must be USE POWER
        unless lef_use_val == "POWER"
          puts "  ERROR: PG_TYPE mismatch LIB=PRIMARY_POWER LEF=#{lef_use_val}"
          errors << "#{cell}\n\tPin #{lib_pin_name}: PG_TYPE mismatch — LIB PRIMARY_POWER but LEF USE=#{lef_use_val} (expected POWER)\n"
        end
      when "PRIMARY_GROUND"
        # Must be USE GROUND
        unless lef_use_val == "GROUND"
          puts "  ERROR: PG_TYPE mismatch LIB=PRIMARY_GROUND LEF=#{lef_use_val}"
          errors << "#{cell}\n\tPin #{lib_pin_name}: PG_TYPE mismatch — LIB PRIMARY_GROUND but LEF USE=#{lef_use_val} (expected GROUND)\n"
        end
      else
        # LIB pg_type IS NOT primary power/ground → LEF must NOT map to POWER or GROUND
        if ["POWER", "GROUND"].include?(lef_use_val)
          puts "  ERROR: Non-power pin mapped to power/ground in LEF"
          errors << "#{cell}\n\tPin #{lib_pin_name}: PG_TYPE mismatch — LIB non-power pin but LEF USE=#{lef_use_val}\n"
        end
      end
=end
    elsif lib_pin_prop_key.upcase == "CLOCK" 

        # normalize Liberty clock value
        lib_clock_val = lib_pin.property("clock")
        lib_clock_val = lib_clock_val.to_s.gsub(/[\";]/, "").strip.upcase
        lib_clock_val = "FALSE" if lib_clock_val.empty?

        # find USE in LEF
        lef_use_lines = lef_pin.properties.select do |prop_str|
          prop_str.strip.upcase.start_with?("USE")
        end

        if lef_use_lines.empty?
          errors << "#{cell}\n\tPin #{lib_pin_name}: Missing LEF USE property\n"
          return errors
        end

        lef_use_val = lef_use_lines.first.split[1].gsub(/[\";]/, "").strip.upcase

        if lib_clock_val == "TRUE"
          # clock pins must be USE CLOCK or USE SIGNAL
          valid_clock_uses = ["CLOCK", "SIGNAL"]
          unless valid_clock_uses.include?(lef_use_val)
            puts "  ERROR: CLOCK mismatch LIB=true LEF=#{lef_use_val}"
            errors << "#{cell}\n\tPin #{lib_pin_name}: CLOCK mismatch — LIB clock:true but LEF USE=#{lef_use_val} (expected CLOCK or SIGNAL)\n"
          end

        else # lib_clock_val == "FALSE"
          # clock:false → must NOT use clock
          if lef_use_val == "CLOCK"
            puts "  ERROR: CLOCK mismatch LIB=false but LEF=CLOCK"
            errors << "#{cell}\n\tPin #{lib_pin_name}: CLOCK mismatch — LIB clock:false but LEF USE=CLOCK\n"
          end
        end
    end
    unless lef_pin_prop_str.empty?
      lef_pin_val_str = lef_pin_prop_str.select{|prop_str| !(prop_str =~ lef_prop_val_re).nil?}
      if lef_pin_val_str.empty?
        errors << "#{cell}\n\tFiles: #{lib_path}, #{lef_path}, \n\tPin: #{lib_pin_name}, \n\tProperty: #{lef_prop_key}\n"
      end 
    end

    return errors
  end
end

# Return layers array AND layer types from either tlef or tf file
def get_layers_from_tlef(tlef_fn)
  if tlef_fn.match(/\.tf$/)
    # Cadence .tf file
    tf_obj = TF_File.new(tlef_fn)
    tf_obj.tf_parse()
    return tf_obj.layers, tf_obj.layer_types
  else
    # .tlef file (LEF format)
    tlef_obj = TLEF_File.new(tlef_fn)
    tlef_obj.tlef_parse()
    return tlef_obj.layers, tlef_obj.layer_types
  end
end

private

# WS DIR Parsing (TODO: needs to be method) (This is completed)
def parse_ws_dir(opts)
  proj_dir = opts.wsdir
  liberty_dirpath = opts.libdir
  files_to_use_dict = nil
  liberty_files = []
  lef_files = nil
  tlef_files = nil
  unless proj_dir.nil?
    files_to_use_dict = ddc_scan_from_sysio(proj_dir) 
    lef_files = files_to_use_dict['lef']
    liberty_files = files_to_use_dict['lib']
    tlef_files = files_to_use_dict['tlef']
  end

  unless opts.tlef.nil?
    tlef_files = opts.tlef
  end
  return proj_dir, liberty_dirpath, liberty_files, lef_files, tlef_files
end

################################## LEF Parsing (TODO: needs to be method) (This is completed)
def parse_lef_files(opts, lef_files, tlef_files, errors)
  # Set layer ordering
  layer_order = LayerCollection::layer_order
  LayerCollection::layer_order = layer_order

  # If tlef_file exists, use its layers AND layer types
  if tlef_files
    new_layers, layer_types = get_layers_from_tlef(tlef_files)
    
    print "\n---layers from tlef files---\n[ "
    i = 0
    while i < new_layers.length
      print new_layers[i] + " "
      if (i+1) % 10 == 0
        print "\n  "
      end 
      i += 1
    end
    puts "]\n---end layers---"
    
    # Set layer ordering
    LayerCollection::use_tlef_layers(new_layers)
    
    # Set layer types for cut/routing detection
    if layer_types && !layer_types.empty?
      LayerCollection::set_layer_types(layer_types)
    else
      puts "\nWarning: No layer types found in TLEF file. Using fallback pattern matching."
    end
  else
    puts "\nWarning: No TLEF file provided. Using fallback pattern matching for layer type detection."
  end
  puts ""
  
  if lef_files.nil? || lef_files.empty?
    lef_files = [opts.lef]
  end
  
  # Filter out any nil entries
  lef_files = lef_files.compact

  reportDirectoryExists = nil
  reportDirectoryName = "LEFQA_Report-#{$reportTime.month}_#{$reportTime.day}_#{$reportTime.year}:#{$reportTime.hour}:#{$reportTime.min}:#{$reportTime.sec}"
  
  parsed_lef_files = Hash.new
  lef_files.each { |lef_file_path|
    next if lef_file_path.nil? || lef_file_path.empty?
    
    # Skip if the file is a technology file (not a LEF)
    if lef_file_path.match(/\.(tf|tlef)$/i)
      puts "Skipping technology file: #{lef_file_path}"
      next
    end
    
    lefFile = File.open(lef_file_path,"r")
    lefLines = lefFile.readlines
    lefFile.close()

    comment_lines = Array.new
    index = 0
    lefLines.each do |line|
      if line.match(/\#/)
        comment_lines.push("Line " + (index + 1).to_s() + ": " + line.chomp() + "\n")
        lefLines[index] = line.gsub(/\s*\#.*/, "")
      end
      index += 1
    end
    begin
      if !comment_lines.empty? 
        comments_filename = lef_file_path + "_comments"
        comments_file = File.open(comments_filename, "w")  
        puts "Creating LEF comment file from '#{File.basename(lef_file_path)}' to '#{comments_filename}'"
        comment_lines.each do |line|
          comments_file.write(line)
        end
        comments_file.close()
      end
    rescue Errno::EACCES => e
      puts "Can't create LEF comment file in #{comments_filename}. No permission."

      if reportDirectoryExists
        puts "Placing comment file in the report directory within user's home."
        comments_filename = ENV['HOME'] + "/" + reportDirectoryName + "/commentFiles/" + File.basename(comments_filename)
        comments_file = File.open(comments_filename, "w")
        comment_lines.each do |line|
          comments_file.write(line)
        end
        comments_file.close()
      end

      if !reportDirectoryExists
        puts "Creating Directory #{reportDirectoryName} in user's home directory." 
        reportDirectoryCommand = "mkdir ~/'#{reportDirectoryName}'" 
        system(reportDirectoryCommand)
        system(reportDirectoryCommand + "/commentFiles")
        reportDirectoryExists = true

        puts "Placing comment file in the report directory within user's home."
        comments_filename = ENV['HOME'] + "/" + reportDirectoryName + "/commentFiles/" + File.basename(comments_filename)
        comments_file = File.open(comments_filename, "w")
        comment_lines.each do |line|
          comments_file.write(line)
        end
        comments_file.close()
      end
    end 

    parsed_lef_file = LEF_File.new(lefLines, errors)
    parsed_lef_file.sort!()
    parsed_lef_files[lef_file_path] = parsed_lef_file
  }
  
  return parsed_lef_files, reportDirectoryName
end

# Lib Parsing (TODO: needs to be method) (This is completed)
def parse_lib_files(opts, liberty_dirpath, liberty_files, errors)
  unless liberty_dirpath.nil? && liberty_files.nil?
    unless liberty_dirpath.nil?
      if liberty_dirpath.match(/[^\/]$/)
        liberty_dirpath += "/"
      end
      # Get the list of Liberty files in the given folder.
      $log.debug("ls")
      liberty_files.concat(`ls -1 #{liberty_dirpath}*.lib`.split("\n"))
    end
    # Make a spot for Liberty data to be stored.
    liberty_data = Hash.new

    # Declare all interesting properties to be scraped.
    cell_properties_of_interest = Array.new
    cell_properties_of_interest.push("area")
    pin_properties_of_interest = Array.new
    pin_properties_of_interest.push("direction")
    pin_properties_of_interest.push("pg_type")
    pin_properties_of_interest.push("voltage_name")
    pin_properties_of_interest.push("related_power_pin")
    pin_properties_of_interest.push("related_ground_pin")
    pin_properties_of_interest.push("clock")
    
    lefcount = 1
    # For every file in the list:
    liberty_files.each do |filename|
      $log.debug("Filename: " + filename)
      print "Parsing liberty files [#{lefcount}/#{liberty_files.length}]...\r"
      $stdout.flush
      # TODO: area, pins, and directions (case sensitive)
      # Find all lines that declare the start of a cell.
      cell_lines_list = `grep -n "^\\s*cell\\s*(.*)\\s*{" #{filename}`
      cell_lines_list = cell_lines_list.split("\n")
      cell_properties_lists = Hash.new
      # For every interesting cell property:
      cell_properties_of_interest.each do |cell_property|
        # Find all lines that define that property.
        cell_properties_lists[cell_property] = `grep -n "^\\s*#{cell_property}\\s:" #{filename}`
        cell_properties_lists[cell_property] = cell_properties_lists[cell_property].split("\n")
      end
      # Find all lines that declare the start of a pin.
      pin_lines_list = `egrep -n "^\\s*(pg_)?pin\\s*(\\(\\S+\\))\\s*{" #{filename}`
      pin_lines_list = pin_lines_list.split("\n")
      pin_properties_lists = Hash.new
      # For every interesting pin property:
      pin_properties_of_interest.each do |pin_property|
        # Find all lines that define that property.
        pin_properties_lists[pin_property] = `grep -n "^\\s*#{pin_property} :" #{filename}`
        pin_properties_lists[pin_property] = pin_properties_lists[pin_property].split("\n")
      end
      liberty_data[filename] = Hash.new
      
      # Using line number information, determine which properties belong to which cells and pins.
      while !(cell_lines_list.empty?)
        next_liberty_cell = Liberty_Cell.new(cell_lines_list, cell_properties_lists, pin_lines_list, pin_properties_lists)
        liberty_data[filename][next_liberty_cell.name()] = next_liberty_cell
      end
      lefcount += 1
    end
    puts ""
    return liberty_data
  end
end

# LEF-LIB Compare (TODO: needs to be method) (This is completed)
# Compare data; run checks.
def compare_lef_lib(parsed_lef_files, liberty_data, errors)
    $log.debug("Comparing LEF-LIB...")

    missing_cells = Hash.new
    area_mismatch = Hash.new
    missing_pins = Hash.new
    lefcount = 1
    parsed_lef_files.each_pair { |lef_filename, parsed_lef_file|
      parsed_lef_file.cells().keys().each do |cell|      
        liberty_data.keys().each do |filename|
          print "Comparing LEF[#{lefcount}/#{parsed_lef_files.length}]='" + File.basename(lef_filename) + "'  to  LIB='" + File.basename(filename) + "'                                                   \r"
          $stdout.flush
          if liberty_data[filename][cell].nil?
            if missing_cells[cell].nil?
              missing_cells[cell] = Array.new
            end
            missing_cells[cell].push(filename)
          else
            Liberty_Cell::properties().each do |liberty_cell_property|
              if liberty_cell_property == "area"
                lef_cell_area = nil
                liberty_cell_area = nil
                parsed_lef_file[cell].properties().each do |lef_cell_property|
                  if lef_cell_property.split()[0].upcase() == "SIZE"
                    lef_cell_dim = lef_cell_property.split()
                    lef_cell_area = lef_cell_dim[1].to_f() * lef_cell_dim[3].to_f()
                  end
                end
                liberty_cell_area = liberty_data[filename][cell].property("area")
                liberty_cell_area = liberty_cell_area.to_f()
                if lef_cell_area.nil?
                  puts "Error: SIZE property not found in LEF file for cell " + cell + "\n"
                end
                if liberty_cell_area.nil?
                  puts "Error: AREA property not found in Liberty file "+ filename + " for cell " + cell + "\n"
                end
                if lef_cell_area != liberty_cell_area
                  if area_mismatch[cell].nil?
                    area_mismatch[cell] = Array.new
                  end
                  area_mismatch[cell].push(filename)
                end
              end
            end
            
            parsed_lef_file.cells()[cell].pins.each do |pin, pin_obj|
              matching_pin = nil
              liberty_data[filename][cell].pins.each do |p|
                if pin.upcase() == p.name.upcase()
                  matching_pin = p
                end
              end

              if matching_pin.nil?
                if missing_pins[cell].nil?
                  missing_pins[cell] = Hash.new
                end
                if missing_pins[cell][pin].nil?
                  missing_pins[cell][pin] = Array.new
                end
                missing_pins[cell][pin].push(filename)
              else
                $log.debug("Pin " + matching_pin.name.upcase() + " exists: checking properties...")
                Liberty_Pin::properties().each do |lib_pin_prop_key|
                  errs = LibRuleChecker.check_pin_value_in_lef(lef_filename, filename, pin_obj, matching_pin, lib_pin_prop_key, cell)
                  errs.each { |err|
                    errors[:liberty_incorrect_pin_property].push(err)
                  }
                end
              end
            end
          end
        end
      end
      lefcount += 1 
    }
    puts "" 
    
    if !(missing_cells.empty?)
      $log.debug("WARNING: missing cells found")
      missing_cells.keys().each do |cell|
        $stdout.flush
        liberty_missing_cell_msg = cell + ":\n"
        missing_cells[cell].each do |filename|
          liberty_missing_cell_msg += "\t" + filename + "\n"
        end
        errors[:liberty_missing_cell].push(liberty_missing_cell_msg)
      end
      puts ""
    end
    if !(area_mismatch.empty?)
      $log.debug("WARNING: area mismatch found")
      area_mismatch_msg = ""
      area_mismatch.keys().each do |cell|
        $stdout.flush
        area_mismatch_msg = cell + ":\n"
        area_mismatch[cell].each do |filename|
          area_mismatch_msg += "\t" + filename + "\n"
        end
      end
      errors[:area_mismatch].push(area_mismatch_msg)
      puts ""
    end
    if !(missing_pins.empty?)
      $log.debug("WARNING: missing pins found")
      liberty_missing_pin_msg = ""
      missing_pins.keys().each do |cell|
        $stdout.flush
        liberty_missing_pin_msg = cell + ":\n"
        missing_pins[cell].keys().each do |pin|
          liberty_missing_pin_msg += "\t" + pin + ":\n"
          missing_pins[cell][pin].each do |filename|
            liberty_missing_pin_msg += "\t\t" + filename + "\n" 
          end
        end
      end
      errors[:liberty_missing_pin].push(liberty_missing_pin_msg)
      puts ""
    end

    lef_missing_cells = Hash.new
    lef_missing_pins = Hash.new
    liberty_data.keys().each do |filename|
      liberty_data[filename].keys().each do |cell|
        parsed_lef_files.each_value { |parsed_lef_file|
          if parsed_lef_file.cells()[cell].nil?
            if lef_missing_cells[cell].nil?
              lef_missing_cells[cell] = Array.new
            end
            lef_missing_cells[cell].push(filename)
          else
            liberty_data[filename][cell].pins()
            liberty_data[filename][cell].pins().each do |pin|
              if parsed_lef_file[cell].pins()[pin.name().upcase()].nil?
                if lef_missing_pins[cell].nil?
                  lef_missing_pins[cell] = Hash.new
                end
                if lef_missing_pins[cell][pin.name()].nil?
                  lef_missing_pins[cell][pin.name()] = Array.new
                end
                lef_missing_pins[cell][pin.name()].push(filename)
              end
            end
          end
        }
      end
    end
    lef_missing_cells.keys().each do |cell|
      lef_missing_cells_msg = cell + ":\n"
      lef_missing_cells[cell].each do |filename|
        lef_missing_cells_msg += "\t" + filename + "\n"
      end
      errors[:lef_missing_cell].push(lef_missing_cells_msg)
    end
    lef_missing_pins.keys().each do |cell|
      lef_missing_pins_msg = cell + ":\n"
      lef_missing_pins[cell].keys().each do |pin|
        lef_missing_pins_msg += "\t" + pin + ":\n"
        lef_missing_pins[cell][pin].each do |filename|
          lef_missing_pins_msg += "\t\t" + filename + "\n"
        end
      end
      errors[:lef_missing_pin].push(lef_missing_pins_msg)
    end
end

# Print file and errors (TODO: needs to be method) (This is completed)
# Print the file
# TODO: the errors are currently printed on error-to-error basis, they should be 
# collected and printed file-to-file. ie. Lib1.lib had these errors, Lib2.lib had 
def print_output_files(parsed_lef_files, errors, reportDirectoryName, opts)

  # other errors
  lefcount = 1   

  parsed_lef_files.each_pair { |lef_filename, parsed_lef_file|
    print "Printing sorted LEF file [#{lefcount}/#{parsed_lef_files.length}] to '" + lef_filename + "                   \r"
    $stdout.flush
    output_filename = lef_filename + "_sorted"
    # TODO: use block format for File.open (This is now complete)
    begin
      File.open(output_filename, "w") do |outFile|
        # REFACTORED: Write the big string all at once
        outFile.print parsed_lef_file.to_s
      end # outFile is automatically closed here

    # Rescues if user does not have permissions to place sorted LEF files within DDC.
    rescue Errno::EACCES => e
      # Generating filepath to the report directory within user's home.
      puts "You cannot place sorted_lef files here, placing them in report directory (see home directory)."

      # Creating the necessary subdirectories within the report directory, found in user's home.
      reportDirectoryCommand = "mkdir ~/'#{reportDirectoryName}'" 
      system(reportDirectoryCommand + "/sortedFiles")

      # Creating sorted_lef filename and path to go in user's report directory.
      output_filename = ENV['HOME'] + "/" + reportDirectoryName + "/sortedFiles/" + File.basename(output_filename)
      File.open(output_filename, "w") do |outFile|
        # REFACTORED: Write the big string all at once
        outFile.print parsed_lef_file.to_s
      end # outFile is automatically closed here
    end
    # First, check if there are ANY errors at all
    has_errors = false
    errors.keys().each do |error_type|
      if !errors[error_type].empty?
        has_errors = true
        break
      end
    end

    # If there were errors, open the error file ONCE and write all errors to it
    if has_errors
      error_filename = lef_filename + "_errors"
      
      begin
        # TODO: use block format for File.open (This is now complete)
        File.open(error_filename, "w") do |error_file|
          error_types = errors.keys()
          error_count = 1 #counter to track tests
          error_header_end = "--------------------------------------------------------------\n"
          error_footer =     "--------------------------------------------------------------\n"
          
          error_types.each do |error_type|
            if !errors[error_type].empty?
              error_description = "\nTest [#{error_count}/#{error_types.length}] \'" + error_type.to_s() + "\' failed.\n"
              
              case error_type
              when :line_ending_semicolons
                error_description += "Warning: The following lines have improper lack of space before the ending semicolon.\n"
                error_description += "These issues are fixed in " + output_filename + ".\n"
              when :strange_origin, :strange_foreign, :strange_class, :strange_site, :strange_symmetry, :strange_direction, :strange_use
                puts "\nTest [#{error_count}/#{error_types.length}] \'" + error_type.to_s() + "\' passed."
                error_count += 1
                next
              when :missing_property_definitions
                error_description += "Warning: The LEF file does not have any PROPERTYDEFINITIONS listed at the start of the file.\n"
              when :missing_end_library_token
                error_description += "Error: The LEF file does not contain an 'END LIBRARY' delimiter.\n"
              when :mangled_cell_end
                error_description += "Error: The following cells have non-matching end delimiters.\n"
              when :missing_cell_end
                error_description += "Error: The following cells are missing end delimiters.\n"
              when :unknown_pin_property
                error_description += "Warning: The following lines specify an unrecognized pin property.\n"
              when :unknown_cell_property
                error_description += "Warning: The following lines specify an unrecognized cell property.\n"
              when :unknown_layer
                error_description += "Warning: The following lines defined unrecognized layers.\n"
              when :missing_origin
                error_description += "Error: The following cells do not have an ORIGIN defined.\n"
              when :missing_class
                error_description += "Error: The following cells do not have a CLASS defined.\n"
              when :missing_site
                error_description += "Error: The following cells do not have a SITE defined.\n"
              when :missing_size
                error_description += "Error: The following cells do not have a SIZE defined.\n"
              when :missing_symmetry
                error_description += "Error: The following cells do not have a SYMMETRY defined.\n"
              when :missing_direction
                error_description += "Error: The following pins do not have a DIRECTION defined.\n"
              when :missing_use
                error_description += "Error: The following pins do not have a USE defined.\n"
              when :missing_via_obs
                error_description += "Error: The following cells have VIA/cut layers in pins without corresponding OBS layers.\n"
                error_description += "VIA layers should have matching OBS definitions for proper DRC compliance.\n"
              when :lef_missing_cell
                error_description += "Error: The following cells were found in Liberty files, but not in the LEF file.\n"
              when :lef_missing_pin
                error_description += "Error: The following cells had the following pins defined in Liberty files, but not in the LEF file.\n"
              when :liberty_missing_cell
                error_description += "Error: The following cells were found in the LEF file, but not in the following Liberty files.\n"
              when :liberty_missing_pin
                error_description += "Error: The following cells had the following pins defined in the LEF file, but not in the following Liberty files.\n"
              when :area_mismatch
                error_description += "Error: The following cells had a SIZE property that was inconsistent with the AREA stated in the following Liberty files.\n"
              when :liberty_incorrect_pin_property
                error_description += "Error: The following cells have mismatched values between LIB and LEF.\n" 
              end
              
              error_description += error_header_end
              puts "\nTest [#{error_count}/#{error_types.length}] \'" + error_type.to_s() + "\' failed."
              ecount = 0
              if errors[error_type].length < 1000
                errors[error_type].each do |line|
                  ecount += 1
                  print "Adding [#{ecount}/#{errors[error_type].length}] lines to error description...          \r"
                  $stdout.flush
                  error_description += line
                end
                print "\n"
              elsif opts.ignore
                emsg = "Too many errors to print every line [#{errors[error_type].length} total error lines]"
                puts emsg
                error_description += emsg
              end
              
              error_description += error_footer
              $log.debug(error_description) 
              error_file.print error_description
            else
              puts "\nTest [#{error_count}/#{error_types.length}] \'" + error_type.to_s() + "\' passed."
            end
            error_count += 1
          end
        end
      
      rescue Errno::EACCES => e
        puts "You cannot place error files here, placing them in report directory (see home directory)."
        reportDirectoryCommand = "mkdir ~/'#{reportDirectoryName}'"
        system(reportDirectoryCommand + "/errorFiles")
        error_filename = ENV['HOME'] + "/" + reportDirectoryName + "/errorFiles/" + File.basename(error_filename)
        File.open(error_filename, "w") do |error_file|
          # Same error handling code...
          error_types = errors.keys()
          error_count = 1
          error_header_end = "--------------------------------------------------------------\n"
          error_footer =     "--------------------------------------------------------------\n"
          
          error_types.each do |error_type|
            if !errors[error_type].empty?
              error_description = "\nTest [#{error_count}/#{error_types.length}] \'" + error_type.to_s() + "\' failed.\n"
              error_description += error_header_end
              errors[error_type].each do |line|
                error_description += line
              end
              error_description += error_footer
              error_file.print error_description
            end
            error_count += 1
          end
        end
      end
    end
    
    lefcount += 1
    puts "\nFiles created are placed here: "
    puts reportDirectoryName
    puts ""
  }
end

def main(opts)
  $log.debug("main")
  
  proj_dir, liberty_dirpath, liberty_files, lef_files, tlef_files = parse_ws_dir(opts)

  errors = Hash.new
  errors[:line_ending_semicolons]       = Array.new 
  errors[:missing_property_definitions] = Array.new
  errors[:missing_end_library_token]    = Array.new
  errors[:mangled_cell_end]             = Array.new
  errors[:missing_cell_end]             = Array.new
  errors[:unknown_pin_property]         = Array.new
  errors[:unknown_cell_property]        = Array.new
  errors[:unknown_layer]                = Array.new
  errors[:missing_origin]               = Array.new
  errors[:strange_origin]               = Array.new
  errors[:strange_foreign]              = Array.new
  errors[:missing_class]                = Array.new
  errors[:strange_class]                = Array.new
  errors[:missing_symmetry]             = Array.new
  errors[:strange_symmetry]             = Array.new
  errors[:missing_size]                 = Array.new
  errors[:missing_site]                 = Array.new
  errors[:strange_site]                 = Array.new
  errors[:missing_direction]            = Array.new
  errors[:strange_direction]            = Array.new
  errors[:missing_use]                  = Array.new
  errors[:strange_use]                  = Array.new
  errors[:missing_via_obs]              = Array.new
  errors[:lef_missing_cell]             = Array.new
  errors[:lef_missing_pin]              = Array.new
  errors[:liberty_missing_cell]         = Array.new
  errors[:liberty_incorrect_pin_property] = Array.new
  errors[:liberty_missing_pin]          = Array.new
  errors[:area_mismatch]                = Array.new
  
  parsed_lef_files, reportDirectoryName = parse_lef_files(opts, lef_files, tlef_files, errors)
  
  liberty_data = parse_lib_files(opts, liberty_dirpath, liberty_files, errors)

  unless liberty_data.nil?
    compare_lef_lib(parsed_lef_files, liberty_data, errors)
  end

  print_output_files(parsed_lef_files, errors, reportDirectoryName, opts)
end

class Liberty_Cell
  attr_reader :name, :pins
  def self.properties()
    return Array["area"]
  end
  def initialize(cell_start_lines, cell_properties, pin_start_lines, pin_properties)
    @properties = Hash.new
    @pins = Array.new
    start_line = cell_start_lines.shift()
    start_line_num = start_line.split(' ')[0].to_i()
    if (cell_start_lines.empty?)
      next_cell_start_line_num = 9E999
    else
      next_cell_start_line_num = cell_start_lines[0].split(' ')[0].to_i()
    end
    @name = start_line.split("\"")[1]
    if @name.nil?
      @name = start_line.split(/\(|\)/)[1]
    end
    Liberty_Cell::properties().each do |property|
      advance_to_line(cell_properties[property], start_line_num)
      if !(cell_properties[property].empty?)
        cellpropline = cell_properties[property][0].gsub("\t","").gsub(" ","").split(':')
        if cellpropline[0].to_i() < next_cell_start_line_num 
          @properties[property] = cell_properties[property].shift().split(': ')[1]
        end
      end
    end
    if !(pin_start_lines.empty?)
      while (pin_start_lines[0].split(' ')[0].to_i() < next_cell_start_line_num)
        next_pin = Liberty_Pin.new(pin_start_lines, pin_properties)
        @pins.push(next_pin)
        if pin_start_lines.empty?
          break
        end
      end
    end
  end
  def property(prop)
    return @properties[prop]
  end
  def searchedProperties()
    return @properties.keys
  end
  def [](ind)
    @pins[ind]
  end
end

class Liberty_Pin
  attr_reader :name
  def self.properties()
    # TODO: if pg_pin, should also check that use in LEF is PWR or GND
    #, "pg_type", "voltage_name", "related_power_pin", "related_ground_pin", "clock"
    return Array["direction", "pg_type", "voltage_name", "related_power_pin", "related_ground_pin", "clock"]
  end
  def initialize(pin_start_lines, pin_properties)
    @properties = Hash.new
    start_line = pin_start_lines.shift()
    if pin_start_lines.empty? || !pin_start_lines.nil? 
      end_of_pins = true
    else 
      end_of_pins = false
    end
    start_line_num = start_line.split(' ')[0].to_i()
    unless pin_properties.empty? || end_of_pins || pin_properties.nil?
      next_pin_start_line_num = pin_start_lines[0].split(' ')[0].to_i()
    end
    @name = start_line.split(/\(|\)/)[1]
    Liberty_Pin::properties().each do |property|
      advance_to_line(pin_properties[property], start_line_num)
      unless pin_properties[property][0].nil?
        if end_of_pins || pin_properties[property][0].split(' ')[0].to_i() < next_pin_start_line_num
          @properties[property] = pin_properties[property].shift().split(': ').last.gsub(/[\";]/, '').strip
        end
      end
    end
  end
  def property(prop)
    return @properties[prop]
  end
  def searchedProperties()
    return @properties.keys
  end
end

def advance_to_line(arr, line_num)
  if arr.empty?
    return
  end
  while arr[0].split(' ')[0].to_i() < line_num
    arr.shift()
    if arr.empty?
      return
    end
  end
end

class DdcScanner
  def self.scan_for_files(proj_dir)
    ddc_dirs = scan_for_dirs(proj_dir)
    dirs_with_files = Hash.new
    ddc_dirs.each_pair{|dir, filetypes|
      dirs_with_files[dir] = Hash.new
      if filetypes.include?('pnr')
        lef_files = scan_for_lef_files(dir)
        dirs_with_files[dir]['lef'] = lef_files
      end
      if filetypes.include?('syn')
        lib_files = scan_for_lib_files(dir)
        dirs_with_files[dir]['lib'] = lib_files
      end
      if filetypes.include?('config')
        conf_files = scan_for_tlef_files(dir)
        dirs_with_files[dir]['tlef'] = conf_files
      end
    }
    return dirs_with_files
  end

  def self.scan_for_dirs(proj_dir)
    find_pnr_cmd = [
      "find",
      "#{proj_dir}",
      "-maxdepth 3",
      "-type d",
      "-name 'pnr'"
    ]
    find_syn_cmd = [
      "find",
      "#{proj_dir}",
      "-maxdepth 3",
      "-type d",
      "-name 'syn'"
    ]
    find_conf_cmd = [
      "find",
      "#{proj_dir}",
      "-maxdepth 2",
      "-type d",
      "-name 'config'"
    ]
    ddc_dirs = Hash.new

    find_dirs_with_cmd(find_conf_cmd, ddc_dirs, "config")
    find_dirs_with_cmd(find_pnr_cmd, ddc_dirs, "pnr")
    find_dirs_with_cmd(find_syn_cmd, ddc_dirs, "syn")
    
    ccount = pcount = scount = 0
    ddc_dirs.each_value { | filetype |
      if filetype.include? "config"
        ccount += 1
      end
      if filetype.include? "pnr"
        pcount += 1
      end
      if filetype.include? "syn"
        scount += 1
      end 
    }
    output = ""
    if ccount < 1
      output << "ERROR: No config directories found.\n"
    end
    if pcount < 1
      output << "ERROR: No pnr directories found.\n"
    end
    if scount < 1 
      output << "WARNING: No syn directories found.\n"
    end
    puts output
    if ccount < 1 || pcount < 1
      exit
    end

    $log.debug(ddc_dirs)
    return ddc_dirs
  end

  def self.find_dirs_with_cmd(find_cmd, ddc_dirs, key)
    find_res = collect_io_results(find_cmd)
    find_res.each { |dir|
      parent = File.expand_path('..', dir)
      if !ddc_dirs[parent].is_a?(Array)
        ddc_dirs[parent] = Array.new
      end
      ddc_dirs[parent] << key
    }
  end

  def self.scan_for_lef_files(ddc_dir)
    find_lef_cmd = [
      "find",
      "-L",
      "#{ddc_dir}/pnr",
      "-type f",
      "-name '*.lef'"
    ]
    return collect_io_results(find_lef_cmd)
  end

  def self.scan_for_lib_files(ddc_dir)
    find_dir_under_syn_cmd = [
      "find",
      "#{ddc_dir}/syn",
      "-maxdepth 1",
      "-type d"
    ]
    dir_under_syn = collect_io_results(find_dir_under_syn_cmd)
    z = 0
    dir_under_syn.each { |dir|
      puts "#{z} = #{dir_under_syn[z]}"
      z += 1
    }
    puts ""
    puts "Please select the directory of .lib files you would like to use from the list of directories above."
    puts "Selecting '0' will use all available .lib files."
    puts ""
    chosen_dir = gets.strip
    chosen_dir = chosen_dir.to_i

    find_lib_cmd = [
      "find",
      "-L",
      "#{dir_under_syn[chosen_dir]}",
      "-type f",
      "-name '*.lib'"
    ]
    return collect_io_results(find_lib_cmd)
  end

  def self.scan_for_tlef_files(projdir)
    find_tlef_cmd = [
      "find",
      "-L",
      "#{projdir}/config/tech/info",
      "-maxdepth 1",
      "-type f",
      "-name '*.tlef'", 
      "-or",
      "-name 'techfile.tf'"
    ]
    return collect_io_results(find_tlef_cmd)
  end

  def self.collect_io_results(cmd_opt_list)
    cmd_str = cmd_opt_list.join(" ")
    res_collection = Array.new
    IO.popen(cmd_str) {|res_io|
      res_io.readlines.each { |res_line|
        res_collection << res_line.gsub("\n","")
      }
    }
    return res_collection
  end
end

def ddc_scan_from_sysio(proj_dir)
  ddc_dict = DdcScanner.scan_for_files(proj_dir)
  tlef_output = ""
  ddc_output = ""
  found_tlef = nil
  count = 0
  option_dict = Hash.new
  ddc_dict.each_pair { |ddc_dir, file_types_dict|
    if file_types_dict.key?("tlef")
      if !found_tlef.nil? || file_types_dict['tlef'].length > 1
        tlef_output << "\n*WARNING: found multiple TLEFs, using the first one. Specify a TLEF in the args for specific one\n"
      elsif file_types_dict['tlef'].length > 0
        tlef_output << "\n*Using tlef config from #{ddc_dir} : #{file_types_dict['tlef'].first}\n"
        found_tlef = file_types_dict['tlef'].first
      else
        tlef_output << "\n*WARNING: no TLEF found. Using default layer collections"
      end
      next
    end
    if file_types_dict.key?("lef")
      if file_types_dict.key?("lib")
        ddc_output << "#{count+1}. DDC: #{ddc_dir}, found #{file_types_dict['lef'].length} LEF files and #{file_types_dict['lib'].length} LIB files.\n"
      else
        ddc_output << "#{count+1}. DDC: #{ddc_dir}, only found #{file_types_dict['lef'].length} LEF files, no lib found.\n"
      end
      option_dict[(count+1).to_s] = {"lef" => file_types_dict['lef'], "lib" => file_types_dict['lib']}
      count += 1 
    end
  }
  option_dict.keys.each {|ddc_dir|
    option_dict[ddc_dir]["tlef"] = found_tlef
  }
  
  $log.debug("DDC Count = #{count}")
  option_choice = "1"
  if count > 1
    puts "\nMultiple DDC found. Please select one of the following:\n"
    puts ddc_output
    loop do
      print "Select DDC [1-#{count}]:"
      option_choice = gets.strip
      break if (option_choice.to_i <= count) & (option_choice.to_i >= 1)
      puts "Invalid option, please select a number between [1-#{count}]"
    end
  else
    $log.debug("One DDC found, using default option_choice=#{option_choice}")
    puts ddc_output
  end
  
  puts tlef_output
  
  return option_dict[option_choice]
end

if __FILE__ == $0
  begin
    RuntimeOptions = Struct.new(:debug, :wsdir, :lef, :tlef, :libdir, :ignore)
    opts = RuntimeOptions.new(false, Dir.pwd, nil, nil, nil, false)
    
    parser = OptionParser.new do |o|
      o.separator "Description: This script sorts and compares LEF files to LIB files."
      o.separator "             Script must either be run at the top of technology library, or passed a library using the -w option"
      o.separator "             LEF files and LIB dirs are found in working dir under pnr and syn dirs respectively."
      o.separator "             Script uses the first TLEF file found. To specify TLEF file, use -t option."
      o.separator "Options:"
      o.on("-w","--wsdir=WSDIR", "Specify working directory") do |wsdir|  
        if File.directory? File.expand_path(wsdir) then
          opts.wsdir = wsdir
        else
          raise "#{wsdir}: Directory not accessible"
        end
      end
      o.on("-d","--debug", "Print debugging information") do
        opts.debug = true
        $log.level = Logger::DEBUG
        puts "Debug flag detected, printing commands to terminal for debugging purposes."
      end
      o.on("-l", "--liberty=LIBERTY", "Specify liberty file directory.") do |libdir|
        opts.libdir = libdir
      end
      o.on("-t TLEF", "Specify path to technology LEF (.tlef or .tf)") do |tlef|
        if File.exist? File.expand_path(tlef) then
          opts.tlef = tlef
        else
          raise "#{tlef}: File not accessible"
        end
      end
      o.on("-i", "Skip printing large errors (>1000)") do
        opts.ignore = true
      end
      o.on("-s LEF", "Only sort LEF File.") do |lef|
        if File.exist? File.expand_path(lef) then
          opts.lef = lef
          opts.wsdir = nil
        else
          raise "#{lef}: File not accessible"
        end
      end
      o.on_tail("-h", "--help", "Print help") do
        puts parser
        exit! 0
      end
    end
    begin parser.parse!
    rescue => e
      puts e.message
      puts parser
      exit! 1
    end
    if ARGV.empty? && opts.lef.nil? && opts.wsdir == Dir.pwd
      puts parser
    end
    main(opts)

  rescue Exception => e
    raise
    exit! 1
  end
end
