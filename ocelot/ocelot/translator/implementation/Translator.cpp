/*! \file Translator.cpp
	\date Wednesday July 29, 2009
	\author Gregory Diamos <gregory.diamos@gatech.edu>
	\brief The source file for the Translator class
*/

#ifndef TRANSLATOR_CPP_INCLUDED
#define TRANSLATOR_CPP_INCLUDED

#include <ocelot/translator/interface/Translator.h>

namespace translator
{
	Translator::Exception::Exception( const std::string& message ) 
		: hydrazine::Exception( message )
	{
	
	}
		
	Translator::Translator( ir::Instruction::Architecture s, 
		ir::Instruction::Architecture t, 
		OptimizationLevel l ) : optimizationLevel( l ), 
		sourceArchitecture( s ), targetArchitecture( t )
	{
	
	}
	
	Translator::~Translator()
	{
	
	}
	
	std::string Translator::toString(OptimizationLevel level)
	{
		switch(level)
		{
			case ReportOptimization: return "ReportOptimization";
			case DebugOptimization: return "DebugOptimization";
			case InstrumentOptimization: return "InstrumentOptimization";
			case MemoryCheckOptimization: return "MemoryCheckOptimization";
			case BasicOptimization: return "BasicOptimization";
			case AggressiveOptimization: return "AggressiveOptimization";
			case SpaceOptimization: return "SpaceOptimization";
			case FullOptimization: return "FullOptimization";
			default: break;
		}
		return "NoOptimization";
	}
}

#endif

